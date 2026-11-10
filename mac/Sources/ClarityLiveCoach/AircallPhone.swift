import SwiftUI
import WebKit

/// Aircall's own phone (Aircall Workspace, workspace.aircall.io) running inside the coach.
/// The rep signs in once; after that the coach dials through the Aircall API and the call
/// rings out here. No Aircall desktop app and no Aircall panel in Chrome needed.
/// Calls are real Aircall calls, so they log to Salesforce like always.
@MainActor
final class AircallPhone: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AircallPhone()
    nonisolated static let address = URL(string: "https://workspace.aircall.io")!

    /// On by default. Off = use the Aircall desktop app or the Aircall panel in Chrome instead.
    nonisolated static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "appPhone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "appPhone") }
    }

    /// The phone is shown big (to sign in) or tucked away (while calling).
    /// Shown by default; remembers if the rep hides it.
    @Published var shown = UserDefaults.standard.object(forKey: "aircallShown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shown, forKey: "aircallShown") }
    }

    let webView: WKWebView
    private var popups: [NSWindow] = []

    /// Call audio straight from the phone (16 kHz mono 16-bit): isRep = the rep's mic, false = the prospect.
    /// Set by the coach while it listens. No Core Audio tap needed, so nothing glitches.
    var onAudio: ((_ isRep: Bool, _ pcm: Data) -> Void)?
    /// When audio last came straight from the phone, per side.
    private(set) var lastRemoteAudio = Date.distantPast
    private(set) var lastLocalAudio = Date.distantPast

    /// Runs inside the Aircall page before it loads: copies the call's audio (the other person's
    /// side from the WebRTC call, the rep's side from the mic) and hands it to the app.
    private static let audioHook = """
    (function () {
      if (window.__clarityHooked) return; window.__clarityHooked = true;
      var post = function (m) { try { window.webkit.messageHandlers.clarityAudio.postMessage(m); } catch (e) {} };
      var ctx = null;
      // One feed per side. A new call's audio replaces the old one, so old calls' silence
      // never gets mixed into the new call.
      var active = { remote: null, local: null };
      function stop(side) {
        var a = active[side]; if (!a) return;
        try { a.node.onaudioprocess = null; a.src.disconnect(); a.node.disconnect(); a.silent.disconnect(); } catch (e) {}
        active[side] = null;
      }
      function pump(stream, side) {
        try {
          stop(side);
          if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
          if (ctx.state === 'suspended') ctx.resume();
          var src = ctx.createMediaStreamSource(stream);
          var node = ctx.createScriptProcessor(4096, 1, 1);
          var ratio = ctx.sampleRate / 16000;
          node.onaudioprocess = function (e) {
            var input = e.inputBuffer.getChannelData(0);
            var n = Math.floor(input.length / ratio);
            var out = new Int16Array(n);
            for (var i = 0; i < n; i++) { var v = input[Math.floor(i * ratio)]; v = v < -1 ? -1 : (v > 1 ? 1 : v); out[i] = v * 32767; }
            var bytes = new Uint8Array(out.buffer), bin = '';
            for (var j = 0; j < bytes.length; j++) bin += String.fromCharCode(bytes[j]);
            post({ side: side, pcm: btoa(bin) });
          };
          var silent = ctx.createGain(); silent.gain.value = 0;
          src.connect(node); node.connect(silent); silent.connect(ctx.destination);
          var mine = { src: src, node: node, silent: silent };
          active[side] = mine;
          // The call ended: stop this feed.
          stream.getAudioTracks().forEach(function (t) {
            t.addEventListener('ended', function () { if (active[side] === mine) stop(side); });
          });
        } catch (err) { post({ side: 'error', pcm: String(err) }); }
      }
      var Orig = window.RTCPeerConnection;
      if (Orig) {
        var Hooked = function (a, b) {
          var pc = new Orig(a, b);
          (window.__clarityPCs = window.__clarityPCs || []).push(pc); // only kept to press keys (DTMF)
          pc.addEventListener('track', function (ev) {
            if (ev.track && ev.track.kind === 'audio') pump(ev.streams && ev.streams[0] ? ev.streams[0] : new MediaStream([ev.track]), 'remote');
          });
          return pc;
        };
        Hooked.prototype = Orig.prototype;
        Object.setPrototypeOf(Hooked, Orig);
        window.RTCPeerConnection = Hooked;
      }
      var md = navigator.mediaDevices;
      if (md && md.getUserMedia) {
        var gum = md.getUserMedia.bind(md);
        md.getUserMedia = function (c) {
          return gum(c).then(function (stream) {
            if (stream.getAudioTracks().length) pump(stream, 'local');
            return stream;
          });
        };
      }
    })();
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.audioHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.websiteDataStore = .default() // stays signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 376, height: 600), configuration: config)
        // Aircall supports Chrome; look like Chrome so it doesn't refuse to load.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        config.userContentController.add(self, name: "clarityAudio")
    }

    // MARK: Call audio from the page

    /// True if a 16-bit chunk has more than near-silence in it.
    private static func hasSound(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return false }
            var peak: Int32 = 0
            for s in samples { peak = max(peak, abs(Int32(s))) }
            return peak > 300 // about -40 dB
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let side = body["side"] as? String,
              let payload = body["pcm"] as? String else { return }
        switch side {
        case "remote", "local":
            guard let pcm = Data(base64Encoded: payload) else { return }
            // Only count real sound: silent chunks mean the page isn't really sharing the call.
            if Self.hasSound(pcm) {
                if side == "remote" { lastRemoteAudio = Date() } else { lastLocalAudio = Date() }
            }
            onAudio?(side == "local", pcm)
        default:
            ActivityLog.add("Aircall phone audio: \(payload)")
        }
    }

    /// Loads the phone once, when the coach opens.
    func start() {
        guard Self.isOn, webView.url == nil else { return }
        webView.load(URLRequest(url: Self.address))
    }

    func reload() { webView.load(URLRequest(url: Self.address)) }

    /// Hangs up the call in the phone by clicking Aircall's own hang-up button, like the rep would.
    /// Never touches the call's audio connection. True if it found and clicked the button.
    func hangUp() async -> Bool {
        let js = #"""
        (function () {
          function deep(root, out) {
            var l = root.querySelectorAll('button,[role=button]');
            for (var i = 0; i < l.length; i++) out.push(l[i]);
            var all = root.querySelectorAll('*');
            for (var j = 0; j < all.length; j++) if (all[j].shadowRoot) deep(all[j].shadowRoot, out);
            return out;
          }
          var re = /hang[ _-]?up|end[ _-]?call|end the call/i;
          var buttons = deep(document, []);
          for (var i = 0; i < buttons.length; i++) {
            var b = buttons[i];
            if (!b.getClientRects().length || b.disabled) continue;
            var own = (b.textContent || '').trim();
            var words = [b.getAttribute('aria-label'), b.getAttribute('title'), b.getAttribute('data-test'),
                         b.getAttribute('data-testid'), own.length < 20 ? own : ''].join(' ');
            if (re.test(words)) { b.click(); return 'button'; }
          }
          return 'none';
        })()
        """#
        let result = (try? await webView.evaluateJavaScript(js)) as? String ?? "none"
        ActivityLog.add("Aircall phone hang-up: \(result)")
        return result == "button"
    }

    /// Presses keys in the live call (phone menus): sends the tones through the call's own audio
    /// sender, the way a keypad does. Never changes or closes the call. True if a live call took them.
    func sendDigits(_ digits: String) async -> Bool {
        let keys = digits.filter { "0123456789*#".contains($0) }
        guard !keys.isEmpty else { return false }
        let js = """
        (function () {
          var pcs = window.__clarityPCs || [];
          for (var i = pcs.length - 1; i >= 0; i--) {
            var pc = pcs[i];
            if (pc.connectionState === 'closed' || pc.signalingState === 'closed') continue;
            var senders = pc.getSenders ? pc.getSenders() : [];
            for (var j = 0; j < senders.length; j++) {
              var s = senders[j];
              if (s.track && s.track.kind === 'audio' && s.dtmf && s.dtmf.canInsertDTMF !== false) {
                s.dtmf.insertDTMF('\(keys)', 150, 80);
                return 'sent';
              }
            }
          }
          return 'none';
        })()
        """
        let result = (try? await webView.evaluateJavaScript(js)) as? String ?? "none"
        return result == "sent"
    }

    // MARK: WKUIDelegate

    /// The phone needs the mic for calls. Only Aircall gets it.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.hasSuffix("aircall.io") ? .grant : .deny)
    }

    /// Sign-in pop-ups (like "Sign in with Google") open in their own small window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popup
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { window in
            guard window.contentView === webView else { return false }
            window.close()
            return true
        }
    }
}

/// The phone on screen. Kept in the coach window even when tucked away,
/// so it keeps running (a hidden page can lose its mic).
struct AircallPhoneView: NSViewRepresentable {
    let phone: AircallPhone

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        place(phone.webView, in: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        if phone.webView.superview !== box { place(phone.webView, in: box) }
    }

    /// Takes only the space it's given; never asks for more (so the window doesn't grow).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func place(_ web: WKWebView, in box: NSView) {
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            web.topAnchor.constraint(equalTo: box.topAnchor),
            web.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}

/// "Aircall phone" bar in the coach: Show opens the phone on the right, Hide tucks it away.
struct AircallPhonePanel: View {
    @ObservedObject var phone = AircallPhone.shared
    @AppStorage("nextDials") private var autoDial = true
    @AppStorage("doubleTap") private var doubleTap = true
    @AppStorage("aircallNumberID") private var numberID = 0
    @State private var numbers: [Aircall.Number] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.circle")
            Text("Aircall phone").font(.callout.weight(.semibold))
            Toggle("Auto-dial", isOn: $autoDial)
                .toggleStyle(.checkbox)
                .help("On: after you send the text, the next person loads and is called after a 5 second countdown.")
            Toggle("Double tap", isOn: $doubleTap)
                .toggleStyle(.checkbox)
                .help("On: if they don't pick up, the app calls them a 2nd time. Off: one call per lead, then the next person.")
            if !numbers.isEmpty {
                // The app dials through Aircall's system, so it needs to be told which line to use.
                Picker("From", selection: $numberID) {
                    if !numbers.contains(where: { $0.id == numberID }) { Text("Pick number").tag(0) }
                    ForEach(numbers) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Calls and texts go out from this Aircall number")
            }
            Spacer(minLength: 0)
            if phone.shown {
                Button("Reload") { phone.reload() }
            }
            Button(phone.shown ? "Hide" : "Show") { phone.shown.toggle() }
        }
        .task { numbers = (try? await Aircall.numbers()) ?? [] }
    }
}

/// The phone itself, on the right side of the coach. Always on screen (1 point wide when
/// hidden), so calls keep working.
struct AircallPhoneSide: View {
    static let width: CGFloat = 400
    @ObservedObject var phone = AircallPhone.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if phone.shown {
                Text("Sign in once. Then set yourself to Available. Calls ring here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AircallPhoneView(phone: phone)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(phone.shown ? 12 : 0)
        .frame(width: phone.shown ? Self.width : 1)
        .opacity(phone.shown ? 1 : 0.02)
        .onAppear { phone.start() }
    }
}
