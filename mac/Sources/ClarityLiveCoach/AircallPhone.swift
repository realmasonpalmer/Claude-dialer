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
        get { true } // always: the Aircall phone lives inside the coach
        set { _ = newValue }
    }

    /// The phone always shows on the right of the coach (Mason asked to remove the Show/Hide and
    /// Reload buttons; Reload lives in Settings > Get help). A rep who hid it before gets it back.
    @Published var shown = true

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
      var lastLocal = null; // the mic stream, in case the phone keeps one open across calls
      var idleTicks = 0;
      function live(stream) {
        try { return stream.getAudioTracks().some(function (t) { return t.readyState === 'live'; }); } catch (e) { return false; }
      }
      function stop(side) {
        var a = active[side]; if (!a) return;
        try { a.node.onaudioprocess = null; a.src.disconnect(); a.node.disconnect(); a.silent.disconnect(); } catch (e) {}
        active[side] = null;
      }
      // Between calls the audio context is closed, so the app never keeps the Mac's speakers open.
      // A context left running across calls goes out of step with the speakers when the mic turns
      // on and off (the Mac changes its sound speed for calls): sound gets high-pitched and choppy.
      function closeIfIdle() {
        if (active.remote || active.local || !ctx) return;
        var old = ctx; ctx = null;
        try { old.close(); } catch (e) {}
      }
      setInterval(function () {
        ['remote', 'local'].forEach(function (side) { if (active[side] && !live(active[side].stream)) stop(side); });
        // No call audio for 6 seconds: the call is over. Stop copying the mic too.
        idleTicks = active.remote ? 0 : idleTicks + 1;
        if (idleTicks >= 3) stop('local');
        closeIfIdle();
      }, 2000);
      function pump(stream, side) {
        try {
          stop(side);
          if (!ctx) {
            ctx = new (window.AudioContext || window.webkitAudioContext)();
            post({ side: 'info', pcm: 'audio copy started at ' + ctx.sampleRate + ' Hz' });
          }
          if (ctx.state === 'suspended') ctx.resume();
          idleTicks = 0;
          var src = ctx.createMediaStreamSource(stream);
          var node = ctx.createScriptProcessor(4096, 1, 1);
          node.onaudioprocess = function (e) {
            var input = e.inputBuffer.getChannelData(0);
            var ratio = (e.inputBuffer.sampleRate || 48000) / 16000; // the real speed of this chunk
            var n = Math.floor(input.length / ratio);
            var out = new Int16Array(n);
            for (var i = 0; i < n; i++) { var v = input[Math.floor(i * ratio)]; v = v < -1 ? -1 : (v > 1 ? 1 : v); out[i] = v * 32767; }
            var bytes = new Uint8Array(out.buffer), bin = '';
            for (var j = 0; j < bytes.length; j++) bin += String.fromCharCode(bytes[j]);
            post({ side: side, pcm: btoa(bin) });
          };
          var silent = ctx.createGain(); silent.gain.value = 0;
          src.connect(node); node.connect(silent); silent.connect(ctx.destination);
          var mine = { src: src, node: node, silent: silent, stream: stream };
          active[side] = mine;
          if (side === 'local') lastLocal = stream;
          // The phone kept its mic stream from the last call: copy the rep's side again.
          if (side === 'remote' && !active.local && lastLocal && live(lastLocal)) pump(lastLocal, 'local');
          // The call ended: stop this feed.
          stream.getAudioTracks().forEach(function (t) {
            t.addEventListener('ended', function () { if (active[side] === mine) { stop(side); closeIfIdle(); } });
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
        // The headset's own microphone is never opened. A Bluetooth headset switches to call mode (a different
        // sound speed) whenever any app uses its mic, and that switch is what makes voices jump octaves up and
        // down. So every mic request goes to the Mac's built-in microphone, and the headset stays in one mode
        // (music quality) for the whole session. Only a Mac with no built-in mic falls back to holding the
        // headset in call mode, checked every few seconds.
        var KEY = 'clarityBuiltInMicId', builtIn = null, triedFind = false, finding = null;
        try { builtIn = window.localStorage.getItem(KEY); } catch (e) {}
        var OWN = /built-?in|macbook|imac|mac mini|mac studio|mac pro/i;
        var HEADSET = /bluetooth|airpods|headset|headphone|beats|bose|jabra|plantronics|poly|usb/i;
        var stopTracks = function (s) { s.getTracks().forEach(function (t) { t.stop(); }); };
        var pick = function (list) {
          var mine = list.filter(function (d) { return d.kind === 'audioinput' && d.label && OWN.test(d.label) && !HEADSET.test(d.label); })[0];
          return mine ? mine.deviceId : null;
        };
        var discover = function () {
          if (finding) return finding;
          triedFind = true;
          finding = md.enumerateDevices().then(function (list) {
            var id = pick(list);
            if (id) return id;
            // Device names stay hidden until the page has had the mic once: ask once, let go at once.
            return gum({ audio: true }).then(function (s) { stopTracks(s); return md.enumerateDevices(); }).then(pick);
          }).then(function (id) {
            builtIn = id; finding = null;
            try { if (id) window.localStorage.setItem(KEY, id); } catch (e) {}
            post({ side: 'info', pcm: id ? "mic pinned to the Mac's own microphone: the headset stays in one mode" : 'no built-in microphone found: using the headset mic' });
            if (!id) startHold();
            return id;
          }).catch(function (e) {
            finding = null;
            post({ side: 'info', pcm: 'could not look for the built-in mic: ' + e });
            return null;
          });
          return finding;
        };
        var pinned = function (c) {
          if (!builtIn || !c || !c.audio) return c;
          var out = {}, aud = {}, k;
          for (k in c) out[k] = c[k];
          if (typeof c.audio === 'object') for (k in c.audio) aud[k] = c.audio[k];
          aud.deviceId = { exact: builtIn };
          out.audio = aud;
          return out;
        };
        // Fallback only (no built-in mic): keep the headset in call mode, and take that back if it is lost.
        var holdStarted = false;
        var startHold = function () {
          if (holdStarted) return; holdStarted = true;
          var holding = false, holdFailures = 0;
          var hold = function () {
            if (holding || holdFailures >= 5) return;
            var kept = window.__clarityKeepStream;
            if (kept && live(kept)) return;
            holding = true;
            gum({ audio: true }).then(function (s) { holding = false; holdFailures = 0; window.__clarityKeepStream = s; })
              .catch(function (e) { holding = false; holdFailures++; post({ side: 'info', pcm: 'could not hold the mic open: ' + e }); });
          };
          hold(); setInterval(hold, 4000);
        };
        md.getUserMedia = function (c) {
          var first = (c && c.audio && !builtIn && !triedFind) ? discover() : Promise.resolve(builtIn);
          return first.then(function () {
            var pc = pinned(c);
            return gum(pc).catch(function (e) {
              if (pc === c) throw e;
              // The saved built-in mic id no longer works: forget it and ask the normal way.
              try { window.localStorage.removeItem(KEY); } catch (x) {}
              builtIn = null; triedFind = false;
              return gum(c);
            });
          }).then(function (stream) {
            if (stream.getAudioTracks().length) pump(stream, 'local');
            return stream;
          });
        };
        // A headset connecting or leaving changes the device list: check the built-in mic is still there.
        if (md.addEventListener) md.addEventListener('devicechange', function () {
          md.enumerateDevices().then(function (list) {
            if (builtIn && !list.some(function (d) { return d.deviceId === builtIn; })) { builtIn = null; triedFind = false; discover(); }
          }).catch(function () {});
        });
        // Find the built-in mic before the first call, not during it.
        setTimeout(function () { if (!builtIn && !triedFind) discover(); }, 1500);
      }
    })();
    """

    /// Clarity colors on Aircall's phone. Aircall's class names change with each release, so instead
    /// of targeting them this finds every dark gray background or border and swaps it for the
    /// matching shade of Clarity navy. Colored parts (green call buttons, red badges) stay as they are.
    /// Runs again whenever the page changes.
    private static let navyTheme = """
    (function () {
      if (window.__clarityTheme) return;
      window.__clarityTheme = true;
      var RGB = /rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\)/;
      function gray(c) {
        var m = RGB.exec(c || "");
        if (!m) return null;
        var r = +m[1], g = +m[2], b = +m[3], a = m[4] === undefined ? 1 : +m[4];
        if (a === 0 || Math.max(r, g, b) - Math.min(r, g, b) > 12) return null; // colored: leave it
        return { l: (r + g + b) / 3, a: a };
      }
      // Slate navy for a gray of lightness L: 20 = page #111827, 35 = card #1B2538.
      function slate(L, a) {
        return "rgba(" + Math.round(L * 0.62 + 5) + ", " + Math.round(L * 0.85 + 7) + ", " +
          Math.round(L * 1.15 + 16) + ", " + a + ")";
      }
      function paint() {
        var all = document.querySelectorAll("*");
        for (var i = 0; i < all.length; i++) {
          var el = all[i], cs = getComputedStyle(el), x;
          // Backgrounds: squeeze the grays together so panels and pills barely stand out
          // from the card color. Quiet panel, eyes stay on the script.
          if ((x = gray(cs.backgroundColor)) && x.l < 110)
            el.style.setProperty("background-color", slate(Math.max(28, 30 + (x.l - 20) * 0.35), x.a), "important");
          // Outlines stay clearly visible.
          if (cs.borderTopStyle !== "none" && (x = gray(cs.borderTopColor)) && x.l < 140)
            el.style.setProperty("border-color", slate(Math.max(45, x.l), x.a), "important");
          // Text: bright white becomes soft white; gray details (timestamps, numbers) become muted.
          if ((x = gray(cs.color))) {
            if (x.l > 225) el.style.setProperty("color", "rgba(229, 234, 242, " + x.a + ")", "important");
            else if (x.l > 110) el.style.setProperty("color", "rgba(167, 178, 197, " + x.a + ")", "important");
          }
        }
        document.documentElement.style.setProperty("background-color", "#1B2538", "important");
      }
      var queued = false;
      function later() {
        if (queued) return;
        queued = true;
        setTimeout(function () { queued = false; try { paint(); } catch (e) {} }, 250);
      }
      function start() {
        later();
        new MutationObserver(later).observe(document.documentElement,
          { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
      }
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
      else start();
    })();
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.audioHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.navyTheme, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
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
    /// Is Aircall's red hang-up button on the phone's screen right now? (nil = couldn't tell.)
    /// The button vanishes the moment a call ends, a few seconds before Aircall's API says so.
    func hangUpButtonVisible() async -> Bool? {
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
            if (re.test(words)) return 'yes';
          }
          return 'no';
        })()
        """#
        guard let r = try? await webView.evaluateJavaScript(js) as? String else { return nil }
        return r == "yes"
    }

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

    /// Clicks Aircall's voicemail drop button: the main half of the split button right of the red
    /// hang-up button (its arrow half only picks which message). It drops the DEFAULT message.
    /// `dryRun`: only look for it. `clicked` is true if it was found (and clicked, when not a dry run).
    /// `info` names the button, or lists the buttons it saw, for the activity log.
    func dropVoicemail(dryRun: Bool) async -> (clicked: Bool, info: String) {
        let js = #"""
        (function (DRY) {
          function deep(root, out) {
            var l = root.querySelectorAll('button,[role=button]');
            for (var i = 0; i < l.length; i++) out.push(l[i]);
            var all = root.querySelectorAll('*');
            for (var j = 0; j < all.length; j++) if (all[j].shadowRoot) deep(all[j].shadowRoot, out);
            return out;
          }
          function label(b) {
            return [b.getAttribute('aria-label'), b.getAttribute('title'), b.getAttribute('data-test'),
                    b.getAttribute('data-testid'), b.getAttribute('data-tip'), b.id, b.className && b.className.baseVal === undefined ? b.className : '',
                    (b.textContent || '').trim().slice(0, 30)].join(' ').toLowerCase();
          }
          var buttons = deep(document, []).filter(function (b) { return b.getClientRects().length && !b.disabled; });
          var arrowish = /chevron|arrow|dropdown|caret|expand|more|menu/;
          var skip = /hang|end[ _-]?call|end the call|mute|pause|hold|keypad|transfer|note|tag|contact|insight|add/;
          var main = null, how = '';
          // 1. By name: anything called voicemail / voice mail / drop (not the arrow half).
          var cands = buttons.filter(function (b) { var l = label(b); return /voice[ _-]?mail|vm[ _-]?drop|drop/.test(l) && !skip.test(l); });
          for (var i = 0; i < cands.length && !main; i++) {
            var l = label(cands[i]);
            if (!arrowish.test(l) && cands[i].getAttribute('aria-haspopup') !== 'true') { main = cands[i]; how = 'name'; }
          }
          if (!main && cands.length) { main = cands[0]; how = 'name'; }
          // 2. By place: the first button right after the red hang-up button.
          if (!main) {
            var hang = null;
            for (var k = 0; k < buttons.length && !hang; k++) if (/hang[ _-]?up|end[ _-]?call|end the call/.test(label(buttons[k]))) hang = buttons[k];
            var el = hang;
            for (var depth = 0; el && !main && depth < 3; depth++) {
              var next = el.nextElementSibling;
              if (next) {
                var b = (next.tagName === 'BUTTON' || next.getAttribute('role') === 'button') ? next : next.querySelector('button,[role=button]');
                if (b && b.getClientRects().length) { main = b; how = 'place'; }
              }
              el = el.parentElement;
            }
          }
          if (!main) {
            return 'none:' + buttons.slice(0, 30).map(function (b) { return label(b).replace(/\s+/g, ' ').trim().slice(0, 40); }).join(' | ');
          }
          var name = label(main).replace(/\s+/g, ' ').trim().slice(0, 50) + ' (' + how + ')';
          if (DRY) return 'found:' + name;
          main.click();
          return 'clicked:' + name;
        })(__DRY__)
        """#.replacingOccurrences(of: "__DRY__", with: dryRun ? "true" : "false")
        let raw = (try? await webView.evaluateJavaScript(js)) as? String ?? "none:the phone didn't answer"
        let info = raw.firstIndex(of: ":").map { String(raw[raw.index(after: $0)...]) } ?? raw
        if !raw.hasPrefix("clicked:") && !raw.hasPrefix("found:") { ActivityLog.add("Voicemail drop button: not found. Buttons seen: \(info)") }
        return (raw.hasPrefix("clicked:") || raw.hasPrefix("found:"), info)
    }

    /// Tries to open Aircall's Settings > Call settings (where voicemail drops are recorded) by clicking
    /// its gear and the "Call settings" row. If the phone's layout differs, the rep clicks them by hand.
    func openCallSettings() {
        let js = #"""
        (function () {
          function deep(root, out, sel) {
            var l = root.querySelectorAll(sel);
            for (var i = 0; i < l.length; i++) out.push(l[i]);
            var all = root.querySelectorAll('*');
            for (var j = 0; j < all.length; j++) if (all[j].shadowRoot) deep(all[j].shadowRoot, out, sel);
            return out;
          }
          function lab(b) {
            return [b.getAttribute('aria-label'), b.getAttribute('title'), b.getAttribute('data-test'),
                    b.getAttribute('data-testid'), (b.textContent || '').trim().slice(0, 30)].join(' ').toLowerCase();
          }
          function clickText(text) {
            var els = deep(document, [], '*');
            for (var i = 0; i < els.length; i++) {
              var e = els[i];
              if (e.children.length > 2 || !e.getClientRects().length) continue;
              if ((e.textContent || '').trim().toLowerCase() === text) {
                (e.closest('button,a,[role=button],[role=menuitem],li') || e).click();
                return true;
              }
            }
            return false;
          }
          var buttons = deep(document, [], 'button,[role=button]').filter(function (b) { return b.getClientRects().length; });
          var gear = null;
          for (var i = 0; i < buttons.length && !gear; i++) {
            var l = lab(buttons[i]);
            if (/settings/.test(l) && !/call settings|audio|inbox|network/.test(l)) gear = buttons[i];
          }
          if (gear) gear.click();
          setTimeout(function () { clickText('call settings'); }, 700);
          return gear ? 'gear' : 'no gear';
        })()
        """#
        Task { _ = try? await webView.evaluateJavaScript(js) }
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
    @AppStorage(PrefKey.aircallNumberID) private var numberID = 0
    @AppStorage("aircallTextNumberID") private var textNumberID = 0
    @State private var numbers: [Aircall.Number] = []

    /// The gear in the Outbound Setup header.
    var onSettings: () -> Void = {}
    @EnvironmentObject var coach: CoachModel
    @AppStorage(PrefKey.nextDials) private var autoDial = true
    @AppStorage(PrefKey.doubleTap) private var doubleTap = true
    @AppStorage(PrefKey.autoText) private var autoText = true
    @AppStorage("linkedInBotSend") private var autoLinkedIn = true
    @AppStorage(PrefKey.voicemailDropOn) private var dropOn = false
    @State private var tick = false
    @AppStorage("outboundSetupOpen") private var setupOpen = true

    var body: some View {
        // Outbound Setup: the numbers, calling options and follow-up automation, between calls.
        VStack(alignment: .leading, spacing: 14) {
            Button { setupOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: setupOpen ? "chevron.down" : "chevron.right").font(CardStyle.chevron).foregroundStyle(Brand.subtext)
                    Image(systemName: "slider.horizontal.3").font(CardStyle.icon).foregroundStyle(Brand.blue)
                    Text("Outbound Settings").font(CardStyle.title)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Brand.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if setupOpen {
            // Side by side when there's room, stacked on a narrow window: never wider than the window.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { callsField; textsField }
                VStack(alignment: .leading, spacing: 12) { callsField; textsField }
            }
            // Two boxes side by side when there's room; on a narrow window, one box with both.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    optionBox("Calling Options", icon: "phone") { callingOptions }.tourSpot(.options)
                    optionBox("Follow-Up Automation", icon: "paperplane") { followUpOptions }
                }
                optionBox("Calling Options", icon: "phone") {
                    callingOptions
                    Divider().overlay(Brand.edge)
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane").foregroundStyle(Brand.blue)
                        Text("Follow-Up Automation").font(.body.weight(.semibold)).foregroundStyle(Brand.text)
                    }
                    followUpOptions
                }
                .tourSpot(.options)
            }
            }
        }
        .task {
            numbers = (try? await Aircall.numbers()) ?? []
            Aircall.pickTextNumber(from: numbers)
            textNumberID = UserDefaults.standard.integer(forKey: "aircallTextNumberID")
        }
    }

    private var callsField: some View {
        numberField("CALLS GO OUT FROM", icon: "phone", selection: $numberID, sameAsCalls: false)
            .help("Calls go out from this Aircall number")
    }

    private var textsField: some View {
        numberField("TEXTS GO OUT FROM", icon: "bubble.left", selection: $textNumberID, sameAsCalls: true)
            .help("Texts need a number registered for texting (A2P). Oliver's Portland number is.")
    }

    @ViewBuilder private var callingOptions: some View {
        Toggle("Auto Dial", isOn: $autoDial).toggleStyle(BlueCheck())
            .help("The app calls the next person by itself.")
        Toggle("Call Twice", isOn: $doubleTap).toggleStyle(BlueCheck())
            .help("If they don't pick up, call them one more time right away.")
        Toggle("Mobile Only", isOn: Binding(get: { MobileOnly.on }, set: { MobileOnly.setOn($0); tick.toggle() }))
            .toggleStyle(BlueCheck()).id(tick)
            .help("Skip anyone with no Mobile in Salesforce. Better pick up rates, and every text can go out.")
        // The checkbox turns the time zone order on or off; the dropdown next to it picks which.
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { TimeZoneFilter.selected != nil || TimeZoneFilter.eastCoastFirst },
                set: { on in
                    if on { coach.setTimeZoneFilter(nil); coach.setEastCoastFirst(true) }
                    else { coach.setTimeZoneFilter(nil); coach.setEastCoastFirst(false) }
                    tick.toggle()
                }
            ))
            .toggleStyle(BlueCheck()).id("east\(tick)")
            .help("On: call in time zone order (or one zone only). Off: list order, all zones.")
            zoneMenu
        }
    }

    /// Which time zones to call: all, or one only.
    private var zoneMenu: some View {
        let picked = TimeZoneFilter.selected
        return Menu {
            Button {
                coach.setTimeZoneFilter(nil); coach.setEastCoastFirst(true); tick.toggle()
            } label: {
                if picked == nil && TimeZoneFilter.eastCoastFirst { Label("East Coast First, then West", systemImage: "checkmark") } else { Text("East Coast First, then West") }
            }
            Divider()
            ForEach(CallZone.allCases) { zone in
                Button {
                    coach.setTimeZoneFilter(zone); tick.toggle()
                } label: {
                    let title = "Only \(zone.label) · \(zone.timeNow) there now"
                    if picked == zone { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Text(picked.map { "\($0.label) Only" } ?? "East Coast First").font(.body).foregroundStyle(Brand.text).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 10).padding(.trailing, 30).padding(.vertical, 5)
        .background(Brand.quiet, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.controlEdge, lineWidth: 1))
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.text)
                .frame(width: 18, height: 18)
                .background(Brand.blue, in: RoundedRectangle(cornerRadius: 5))
                .padding(.trailing, 5)
                .allowsHitTesting(false)
        }
        .disabled(coach.status != .ready)
        .help("Call all time zones, or only one")
    }

    @ViewBuilder private var followUpOptions: some View {
        infoToggle("Auto Text", $autoText, "After a voicemail, the text goes out by itself while the next person loads.")
        infoToggle("Auto LinkedIn Connect", $autoLinkedIn, "The app sends the LinkedIn connection request in Chrome in the background.")
        infoToggle("Auto Voicemail Drop", $dropOn, "Drops your recorded voicemail after the beep. Record it first: Settings, then Voicemail drop.")
    }

    private func optionBox<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Brand.blue)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Brand.text)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
        }
        .fixedSize(horizontal: false, vertical: true) // the box always grows to fit what's in it
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.controlEdge, lineWidth: 1))
    }

    private func infoToggle(_ title: String, _ value: Binding<Bool>, _ info: String) -> some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: value).toggleStyle(BlueCheck())
            Image(systemName: "info.circle").font(.caption).foregroundStyle(Brand.subtext).help(info)
        }
    }

    /// A labeled dropdown for an Aircall number: gray caps label, the number's name, one down arrow.
    private func numberField(_ title: String, icon: String, selection: Binding<Int>, sameAsCalls: Bool) -> some View {
        let name = sameAsCalls && selection.wrappedValue == 0 ? "Same as calls"
            : numbers.first { $0.id == selection.wrappedValue }?.name ?? (numbers.isEmpty ? "Aircall not set up" : "Pick a number")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Brand.blue)
                Text(title).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(Brand.subtext)
            }
            Menu {
                if sameAsCalls { Button("Same as calls") { selection.wrappedValue = 0 } }
                ForEach(numbers) { n in
                    Button {
                        selection.wrappedValue = n.id
                    } label: {
                        if n.id == selection.wrappedValue { Label(n.name, systemImage: "checkmark") } else { Text(n.name) }
                    }
                }
            } label: {
                Text(name).font(.body.weight(.medium)).foregroundStyle(Brand.text).lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(numbers.isEmpty)
            // A clear dropdown: a filled box with an edge and the up/down arrows on the right.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12).padding(.trailing, 34).padding(.vertical, 9)
            .background(Brand.quiet, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.controlEdge, lineWidth: 1))
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                    .foregroundStyle(Brand.text)
                    .frame(width: 22, height: 22)
                    .background(Brand.blue, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.trailing, 7)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Sign in one time. Then set yourself to Available. Your calls ring here.")
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

/// Auto dial and Call twice, shown with "Show more" on the coach.
struct DialingSwitches: View {
    @ViewBuilder private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if stacked { VStack(alignment: .leading, spacing: 10, content: content) } else { HStack(spacing: 14, content: content) }
    }

    @AppStorage(PrefKey.nextDials) private var autoDial = true
    @AppStorage(PrefKey.doubleTap) private var doubleTap = true
    var card = true
    /// In the Options popover: one switch per line, time zones as a labeled dropdown.
    var stacked = false
    @State private var mobileTick = false
    @EnvironmentObject var coach: CoachModel

    /// Every time zone setting in one dropdown: all zones, East Coast first, or one zone only.
    private var timeZoneMenu: some View {
        let picked = TimeZoneFilter.selected
        let east = TimeZoneFilter.eastCoastFirst
        return Menu {
            Button {
                coach.setTimeZoneFilter(nil); coach.setEastCoastFirst(true)
            } label: {
                if picked == nil && east { Label("East Coast first, then West", systemImage: "checkmark") } else { Text("East Coast first, then West") }
            }
            Button {
                coach.setTimeZoneFilter(nil); coach.setEastCoastFirst(false)
            } label: {
                if picked == nil && !east { Label("All time zones, list order", systemImage: "checkmark") } else { Text("All time zones, list order") }
            }
            Divider()
            ForEach(CallZone.allCases) { zone in
                Button {
                    coach.setTimeZoneFilter(zone)
                } label: {
                    let title = "Only \(zone.label) · \(zone.timeNow) there now"
                    if picked == zone { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").foregroundStyle(Brand.subtext)
                Text(picked.map { "\($0.label) only" } ?? (east ? "East Coast first" : "All time zones")).foregroundStyle(Brand.text)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Brand.subtext)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(coach.status != .ready)
        .help("Where to call: East Coast first (nobody called before 9 there), all time zones, or one time zone only")
    }

    var body: some View {
        let row = stack {
            Toggle("Auto dial", isOn: $autoDial)
                .toggleStyle(RoundCheck())
                .fixedSize()
                .help("On: the app calls the next person by itself. Off: you click Call each time.")
            Toggle("Call twice", isOn: $doubleTap)
                .toggleStyle(RoundCheck())
                .fixedSize()
                .help("On: if they don't pick up, the app calls them one more time right away. Off: one call, then the next person.")
            Toggle("Mobile only", isOn: Binding(
                get: { MobileOnly.on },
                set: { MobileOnly.setOn($0); mobileTick.toggle() }
            ))
                .toggleStyle(RoundCheck())
                .fixedSize()
                .id(mobileTick)
                .help("On: skip anyone with no Mobile in Salesforce, for the call list in use now. Better pick up rates, and every text can go out.")
            if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Time zones").font(.caption.weight(.semibold)).foregroundStyle(Brand.subtext)
                    timeZoneMenu
                }
            } else {
                Spacer(minLength: 8)
                timeZoneMenu
            }
        }
        .font(.callout)
        if card {
            row.padding(10).frame(maxWidth: .infinity, alignment: .leading).brandCard(radius: 10)
        } else {
            row
        }
    }
}

/// A round check: an empty circle when off, a white filled circle with a dark check when on.
struct RoundCheck: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Brand.controlEdge, lineWidth: 1.5)
                        .background(Circle().fill(configuration.isOn ? Brand.text : Color.clear))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.navy)
                    }
                }
                .frame(width: 18, height: 18)
                configuration.label.foregroundStyle(Brand.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A blue filled square with a white check when on, an outlined square when off.
struct BlueCheck: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(configuration.isOn ? Brand.blue : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(configuration.isOn ? Brand.blue : Brand.controlEdge, lineWidth: 1.5))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
                configuration.label.foregroundStyle(Brand.text).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
