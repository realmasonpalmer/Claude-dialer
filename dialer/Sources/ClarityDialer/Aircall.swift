import SwiftUI
import WebKit

/// Aircall's public REST API: numbers, users, placing calls, call status, texts.
enum Aircall {
    struct Number: Identifiable, Hashable { let id: Int; let name: String; let digits: String }
    struct User: Identifiable, Hashable { let id: Int; let name: String }

    /// Aircall's view of one call.
    struct Call: Equatable {
        let id: Int
        let status: String      // "initial" (ringing), "answered", "done"
        let startedAt: Date?
        let answeredAt: Date?
        let endedAt: Date?
        var isOver: Bool { status == "done" }
    }

    struct AircallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var hasKeys: Bool { Keychain.read(.aircallID) != nil && Keychain.read(.aircallToken) != nil }

    static func numbers() async throws -> [Number] {
        let json = try await request("/numbers?per_page=50")
        return ((json["numbers"] as? [[String: Any]]) ?? []).compactMap { n in
            (n["id"] as? Int).map { Number(id: $0, name: (n["name"] as? String) ?? "Number", digits: (n["digits"] as? String) ?? "") }
        }
    }

    static func users() async throws -> [User] {
        let json = try await request("/users?per_page=50")
        return ((json["users"] as? [[String: Any]]) ?? []).compactMap { u in
            (u["id"] as? Int).map { User(id: $0, name: (u["name"] as? String) ?? "User") }
        }
    }

    /// Rings out from the rep's Aircall phone (the one in the app's side panel).
    static func dial(_ phone: String, user: Int, number: Int) async throws {
        guard let to = Rules.e164(phone) else { throw AircallError(message: "That phone number doesn't look right.") }
        do {
            try await request("/users/\(user)/calls", method: "POST", body: ["number_id": number, "to": to])
        } catch let e as AircallError where e.message.contains("405") {
            throw AircallError(message: "Aircall won't dial: make sure you're signed in to the phone on the right, set to Available, and not already on a call.")
        }
    }

    /// The newest call on this user + number that started after `since`.
    static func latestCall(user: Int, number: Int, since: Date) async throws -> Call? {
        let json = try await request("/calls?order=desc&per_page=10&from=\(Int(since.timeIntervalSince1970) - 5)")
        for c in (json["calls"] as? [[String: Any]]) ?? [] {
            guard ((c["user"] as? [String: Any])?["id"] as? Int) == user,
                  ((c["number"] as? [String: Any])?["id"] as? Int) == number,
                  (c["direction"] as? String) == "outbound",
                  let id = c["id"] as? Int else { continue }
            func date(_ k: String) -> Date? { (c[k] as? Double).map { Date(timeIntervalSince1970: $0) } }
            return Call(id: id, status: (c["status"] as? String) ?? "initial",
                        startedAt: date("started_at"), answeredAt: date("answered_at"), endedAt: date("ended_at"))
        }
        return nil
    }

    /// The call's transcript ("Rep: ..." / "Them: ..." lines), or nil if Aircall hasn't made it yet.
    static func transcript(callID: Int) async throws -> String? {
        let json: [String: Any]
        do { json = try await request("/calls/\(callID)/transcription") } catch let e as AircallError where e.message.contains("404") { return nil }
        guard let content = (json["transcription"] as? [String: Any])?["content"] as? [String: Any],
              let utterances = content["utterances"] as? [[String: Any]] else { return nil }
        var lines: [String] = []
        var last = ""
        for u in utterances {
            let text = ((u["text"] as? String) ?? "").trimmed
            guard !text.isEmpty else { continue }
            let who = (u["participant_type"] as? String) == "internal" ? "Rep" : "Them"
            if who == last, !lines.isEmpty { lines[lines.count - 1] += " " + text } else { lines.append("\(who): \(text)"); last = who }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func sendText(_ body: String, to phone: String, from number: Int) async throws {
        guard let to = Rules.e164(phone) else { throw AircallError(message: "That phone number doesn't look right.") }
        try await request("/numbers/\(number)/messages/native/send", method: "POST", body: ["to": to, "body": body])
    }

    @discardableResult
    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let id = Keychain.read(.aircallID), let token = Keychain.read(.aircallToken) else {
            throw AircallError(message: "Add your Aircall API keys in Settings.")
        }
        var req = URLRequest(url: URL(string: "https://api.aircall.io/v1\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Basic " + Data("\(id):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            if code == 401 { throw AircallError(message: "Aircall didn't accept the API keys.") }
            let detail = (json["message"] as? String) ?? (json["error"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw AircallError(message: "Aircall \(code): \(detail.prefix(200))")
        }
        return json
    }
}

/// Aircall's own phone (workspace.aircall.io), inside the app. Calls placed through the API ring
/// out here. The app only ever clicks Aircall's own Hang up and Voicemail drop buttons.
@MainActor
final class AircallPhone: NSObject, WKUIDelegate {
    static let shared = AircallPhone()
    let webView: WKWebView
    private var popups: [NSWindow] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // stays signed in
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(
            WKUserScript(source: Self.builtInMicOnly, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.minimalScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.navyTheme, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 640), configuration: config)
        // Aircall supports Chrome; look like it so the page loads.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        super.init()
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://workspace.aircall.io")!))
    }

    func reload() { webView.reload() }

    /// Removes Aircall's left sidebar (Conversations, Calls, Campaigns...): only the phone shows.
    /// Found by where it is, not by class names (which change) or labels (gone when Aircall shows
    /// icons only): the narrow column running down the left edge of the page. Re-applied whenever
    /// Aircall redraws.
    private static let minimalScript = """
        (function () {
          var hidden = null;
          function navColumn() {
            var H = window.innerHeight;
            var hit = document.elementFromPoint(8, Math.floor(H / 2)) || document.elementFromPoint(8, 120);
            var best = null;
            for (var el = hit; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
              var r = el.getBoundingClientRect();
              if (r.left <= 2 && r.width >= 40 && r.width <= 140 && r.height >= H * 0.75) best = el;
              else if (r.width > 140) break;
            }
            return best;
          }
          function apply() {
            if (hidden && document.contains(hidden)) return;
            var nav = navColumn();
            if (nav) { nav.style.setProperty('display', 'none', 'important'); hidden = nav; }
          }
          var queued = false;
          new MutationObserver(function () {
            if (queued) return; queued = true;
            setTimeout(function () { queued = false; apply(); }, 250);
          }).observe(document.documentElement, { childList: true, subtree: true });
          window.addEventListener('resize', function () { hidden = null; apply(); });
          apply();
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

    /// One audio path for the whole session. A Bluetooth headset switches into "call mode" (a
    /// different codec and a lower sample rate) the moment any app opens its microphone, and
    /// back when it's released, which makes voices jump in pitch and quality between calls. So the
    /// headset's mic is never opened: every mic request from Aircall goes to the Mac's built-in
    /// microphone, and the headset stays in its normal high-quality mode, one codec and one sample
    /// rate, for every call. (A Mac with no built-in mic uses the default mic.)
    private static let builtInMicOnly = """
        (function () {
          var md = navigator.mediaDevices;
          if (!md || !md.getUserMedia || window.__clarityMic) return;
          window.__clarityMic = true;
          var gum = md.getUserMedia.bind(md), KEY = 'clarityBuiltInMicId', builtIn = null, finding = null;
          try { builtIn = localStorage.getItem(KEY); } catch (e) {}
          var OWN = /built-?in|macbook|imac|mac mini|mac studio|mac pro/i;
          var HEADSET = /bluetooth|airpods|headset|headphone|beats|bose|jabra|plantronics|poly|usb/i;
          function pick(list) {
            var d = list.filter(function (d) { return d.kind === 'audioinput' && d.label && OWN.test(d.label) && !HEADSET.test(d.label); })[0];
            return d ? d.deviceId : null;
          }
          function find() {
            if (builtIn) return Promise.resolve(builtIn);
            if (finding) return finding;
            finding = md.enumerateDevices().then(function (list) {
              var id = pick(list);
              if (id) return id;
              // Device names stay hidden until the page has used the mic once: ask once, let go at once.
              return gum({ audio: true }).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); return md.enumerateDevices(); }).then(pick);
            }).then(function (id) {
              builtIn = id; finding = null;
              try { if (id) localStorage.setItem(KEY, id); } catch (e) {}
              return id;
            }, function () { finding = null; return null; });
            return finding;
          }
          md.getUserMedia = function (c) {
            if (!c || !c.audio) return gum(c);
            return find().then(function (id) {
              if (!id) return gum(c);
              var out = {}, aud = {}, k;
              for (k in c) out[k] = c[k];
              if (typeof c.audio === 'object') for (k in c.audio) aud[k] = c.audio[k];
              aud.deviceId = { exact: id };
              out.audio = aud;
              return gum(out).catch(function () {
                // The saved mic is gone: forget it and use the normal request.
                try { localStorage.removeItem(KEY); } catch (e) {}
                builtIn = null;
                return gum(c);
              });
            });
          };
          if (md.addEventListener) md.addEventListener('devicechange', function () {
            md.enumerateDevices().then(function (list) {
              if (builtIn && !list.some(function (d) { return d.deviceId === builtIn; })) { builtIn = null; try { localStorage.removeItem(KEY); } catch (e) {} }
            });
          });
        })();
        """

    /// Clicks Aircall's red Hang up button. True if it found one.
    func hangUp() async -> Bool { await click(#"/hang[ _-]?up|end[ _-]?call|end the call/"#, avoid: "/^$/") }

    /// Drops the recorded voicemail called `name` (Aircall's arrow next to the drop button lists
    /// them). If that menu can't be found, drops Aircall's default message.
    func dropVoicemail(named name: String) async -> Bool {
        let quoted = name.lowercased().replacingOccurrences(of: "'", with: "\\'")
        // 1. Open the list of recorded drops (the arrow half of the split button).
        if await click(#"/voice[ _-]?mail|vm[ _-]?drop|drop/"#, avoid: "/hang|mute|hold|keypad|transfer/", needsMenu: true) {
            try? await Task.sleep(for: .milliseconds(500))
            // 2. Click the one whose text is the name.
            let js = """
            (function () {
              function deep(root, out) {
                root.querySelectorAll('*').forEach(function (e) { out.push(e); if (e.shadowRoot) deep(e.shadowRoot, out); });
                return out;
              }
              var all = deep(document, []);
              for (var i = 0; i < all.length; i++) {
                var e = all[i];
                if (!e.getClientRects().length || e.children.length > 3) continue;
                if ((e.textContent || '').trim().toLowerCase() === '\(quoted)') {
                  (e.closest('button,[role=option],[role=menuitem],li') || e).click(); return 'yes';
                }
              }
              return 'no';
            })()
            """
            if ((try? await webView.evaluateJavaScript(js)) as? String) == "yes" { return true }
        }
        // Fallback: the main drop button (Aircall's default message).
        return await click(#"/voice[ _-]?mail|vm[ _-]?drop|drop/"#, avoid: #"/chevron|arrow|dropdown|caret|expand|menu|hang|mute|hold|keypad|transfer/"#)
    }

    /// Clicks the first visible button matching `pattern`. `needsMenu`: only a button that opens
    /// a menu (an arrow half); otherwise never one.
    @discardableResult
    private func click(_ pattern: String, avoid: String, needsMenu: Bool = false) async -> Bool {
        let js = """
        (function () {
          function deep(root, out) {
            root.querySelectorAll('button,[role=button]').forEach(function (b) { out.push(b); });
            root.querySelectorAll('*').forEach(function (e) { if (e.shadowRoot) deep(e.shadowRoot, out); });
            return out;
          }
          var want = \(pattern)i, avoid = \(avoid)i;
          var bs = deep(document, []);
          for (var i = 0; i < bs.length; i++) {
            var b = bs[i];
            if (!b.getClientRects().length || b.disabled) continue;
            var t = (b.textContent || '').trim();
            var words = [b.getAttribute('aria-label'), b.getAttribute('title'), b.getAttribute('data-test'),
                         b.getAttribute('data-testid'), t.length < 30 ? t : ''].join(' ');
            var menu = b.getAttribute('aria-haspopup') === 'true' || b.getAttribute('aria-haspopup') === 'menu' || b.getAttribute('aria-haspopup') === 'listbox';
            if (want.test(words) && !avoid.test(words) && menu === \(needsMenu)) { b.click(); return 'yes'; }
          }
          return 'no';
        })()
        """
        return ((try? await webView.evaluateJavaScript(js)) as? String) == "yes"
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.hasSuffix("aircall.io") ? .grant : .deny)
    }

    /// Sign-in pop-ups ("Sign in with Google") open in a small window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        let w = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in"
        w.contentView = popup
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { w in
            guard w.contentView === webView else { return false }
            w.close()
            return true
        }
    }
}

/// The phone, `width` wide.
struct AircallPane: View {
    let width: CGFloat
    var body: some View { AircallPhoneView().frame(width: width) }
}

struct AircallPhoneView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { AircallPhone.shared.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
