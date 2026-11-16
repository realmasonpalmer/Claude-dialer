import Foundation

/// Sends the LinkedIn connection note in the rep's own Chrome (their own LinkedIn sign-in).
/// Opens the profile in a new tab, checks their current company matches Salesforce, clicks
/// Connect > Add a note, types the note, then either clicks Send (auto) or brings the tab up
/// and watches for the rep's own Send click. Closes the tab after.
///
/// Guard rails, so the account stays safe:
/// - At most `dailyCap` invites a day, with human-like pauses between clicks.
/// - A login page, security check, CAPTCHA or limit warning: stop, touch nothing, pause 2 hours.
/// - Never sends a message, never follows, never opens InMail. Never touches a tab it didn't open.
@MainActor
enum LinkedInBot {
    enum Result {
        case sent, alreadyConnected, pending
        case skipped(String)
        case blocked(String)
    }

    static let dailyCap = 20
    static var running = false

    static var isOn: Bool { true }
    /// On: clicks Send itself. Off: types the note and waits for the rep to click Send.
    static var autoSend: Bool { UserDefaults.standard.object(forKey: "linkedInBotSend") as? Bool ?? true }

    static var pausedUntil: Date? {
        get { UserDefaults.standard.object(forKey: "linkedInBotPausedUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "linkedInBotPausedUntil") }
    }

    private static var todayKey: String { "linkedInBotSent-" + Date().formatted(.iso8601.year().month().day()) }
    static var sentToday: Int { UserDefaults.standard.integer(forKey: todayKey) }

    /// Why the bot won't run right now, or nil if it can.
    static var whyNot: String? {
        if running { return "already busy" }
        if let until = pausedUntil, until > Date() { return "paused after a LinkedIn warning until \(until.formatted(date: .omitted, time: .shortened))" }
        if sentToday >= dailyCap { return "hit today's limit of \(dailyCap)" }
        return nil
    }

    /// The note: Claude's, trimmed to LinkedIn's 200 characters, or the plain one.
    static func note(_ written: String, first: String) -> String {
        var text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let rep = Prefs.repName.split(separator: " ").first.map(String.init) ?? "Mason"
            text = "Hi \(first), I'm \(rep) at Clarity Consulting in Portland. We help owners and revenue leaders cut manual customer-record work with AI. Would like to connect."
        }
        guard text.count > 200 else { return text }
        let cut = String(text.prefix(200))
        if let end = cut.lastIndex(where: { ".!?".contains($0) }) { return String(cut[...end]) }
        return String(cut.prefix(197)) + "..."
    }

    /// "ExitLag, Inc." -> ["exitlag"]. Matched against the top of their profile.
    static func companyKeys(_ company: String?) -> [String] {
        guard let company else { return [] }
        let cleaned = company.lowercased().replacingOccurrences(of: #"[^a-z0-9& ]+"#, with: " ", options: .regularExpression)
        let drop: Set<String> = ["inc", "llc", "ltd", "corp", "co", "corporation", "company", "the", "pc", "pllc", "lp", "llp", "group"]
        let words = cleaned.split(separator: " ").map(String.init).filter { !drop.contains($0) }
        guard let first = words.first else { return [] }
        return Array(Set([words.joined(separator: " "), first])).filter { $0.count >= 3 }
    }

    // MARK: The run

    static func connect(profile: URL, note: String, company: String?, onStatus: @escaping (String) -> Void) async -> Result {
        running = true
        defer { running = false }
        guard let tab = await openTab(profile), !tab.isEmpty, tab != "ERR" else {
            return .skipped("Chrome didn't open the tab")
        }
        let result = await run(tab: tab, note: note, keys: companyKeys(company), onStatus: onStatus)
        switch result {
        case .sent: UserDefaults.standard.set(sentToday + 1, forKey: todayKey)
        case .blocked: pausedUntil = Date().addingTimeInterval(2 * 3600)
        default: break
        }
        // A blocked page stays open so the rep can see it; everything else closes.
        if case .blocked = result {} else { await closeTab(tab) }
        return result
    }

    private static func run(tab: String, note: String, keys: [String], onStatus: (String) -> Void) async -> Result {
        func step(_ phase: String) async -> String { await js(tab: tab, phase: phase, note: note, keys: keys) }
        func blocked(_ s: String) -> Result? { s.hasPrefix("BLOCKED:") ? .blocked(String(s.dropFirst(8))) : nil }

        onStatus("LinkedIn: opening their profile...")
        var state = "LOADING"
        for _ in 0..<25 {
            await pause(1, 1.5)
            state = await step("check")
            if state != "LOADING" { break }
        }
        if let b = blocked(state) { return b }
        switch state {
        case "NOJS": return .skipped("Chrome blocked the script (View > Developer > Allow JavaScript from Apple Events)")
        case "LOADING": return .skipped("their profile didn't load")
        case "NOMATCH": return .skipped("their current company on LinkedIn doesn't match Salesforce")
        case "PENDING": return .pending
        case "CONNECTED": return .alreadyConnected
        default: break
        }

        onStatus("LinkedIn: clicking Connect...")
        await pause(1.5, 3)
        var c = await step("connect")
        if c == "MORE" {
            await pause(1, 2)
            c = await step("menu")
        }
        if let b = blocked(c) { return b }
        guard c == "CLICKED" else { return .skipped("no Connect button on their profile") }

        var n = "WAIT"
        for _ in 0..<10 {
            await pause(1, 1.8)
            n = await step("note")
            if n != "WAIT" { break }
        }
        if let b = blocked(n) { return b }
        switch n {
        case "TEXTAREA": break
        case "EMAIL": _ = await step("close"); return .skipped("LinkedIn wants their email to connect")
        case "NONOTE": _ = await step("close"); return .skipped("no free notes left this month (LinkedIn wants Premium)")
        default: _ = await step("close"); return .skipped("Add a note didn't open")
        }

        onStatus("LinkedIn: typing the note...")
        await pause(1, 2)
        guard await step("type") == "TYPED" else {
            _ = await step("close")
            return .skipped("couldn't type the note")
        }

        if autoSend {
            await pause(1.5, 3)
            guard await step("send") == "CLICKED" else {
                _ = await step("close")
                return .skipped("couldn't find the Send button")
            }
            for _ in 0..<10 {
                await pause(1, 1.5)
                let v = await step("verify")
                if let b = blocked(v) { return b }
                if v == "SENT" || v == "CLOSED" { return .sent }
            }
            return .skipped("Send was clicked but LinkedIn didn't confirm")
        }

        // The rep clicks Send: bring the tab up and watch for the click.
        onStatus("LinkedIn: note is typed. Click Send in Chrome and we'll move on.")
        _ = await step("watch")
        await showTab(tab)
        for _ in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            let v = await step("verify")
            if let b = blocked(v) { return b }
            if v == "SENT" { return .sent }
            if v == "CLOSED" { return .skipped("the note was closed without sending") }
            if v == "NOTAB" { return .skipped("the LinkedIn tab was closed") }
        }
        return .skipped("no Send click in 3 minutes")
    }

    private static func pause(_ low: Double, _ high: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(Double.random(in: low...high) * 1000)))
    }

    // MARK: Chrome

    private static let queue = DispatchQueue(label: "clarity.linkedin-bot")

    private static func apple(_ source: String) async -> String? {
        await withCheckedContinuation { done in
            queue.async {
                let r = NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue
                done.resume(returning: r)
            }
        }
    }

    /// A new tab in the front Chrome window, without taking the rep away from their tab.
    private static func openTab(_ url: URL) async -> String? {
        let link = url.absoluteString
        guard !link.contains("\""), !link.contains("\\") else { return nil }
        return await apple("""
        tell application "Google Chrome"
            if (count of windows) = 0 then make new window
            set w to window 1
            set oldIndex to active tab index of w
            set t to make new tab at end of tabs of w with properties {URL:"\(link)"}
            set active tab index of w to oldIndex
            return (id of t) as text
        end tell
        """)
    }

    private static func onTab(_ tab: String, _ action: String) -> String {
        """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if ((id of t) as text) is "\(tab)" then
                        \(action)
                    end if
                end repeat
            end repeat
            return "NOTAB"
        end tell
        """
    }

    private static func closeTab(_ tab: String) async {
        _ = await apple(onTab(tab, "close t\n return \"OK\""))
    }

    /// Brings the LinkedIn tab and Chrome to the front, for the rep's Send click.
    private static func showTab(_ tab: String) async {
        _ = await apple("""
        tell application "Google Chrome"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if ((id of t) as text) is "\(tab)" then
                        set active tab index of w to i
                        set index of w to 1
                        activate
                        return "OK"
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    private static func js(tab: String, phase: String, note: String, keys: [String]) async -> String {
        let args = (try? JSONSerialization.data(withJSONObject: [phase, note, keys])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let code = "(\(script)).apply(null, \(args))"
        let b64 = Data(code.utf8).base64EncodedString()
        let r = await apple(onTab(tab, "return execute t javascript \"eval(decodeURIComponent(escape(atob('\(b64)'))))\""))
        return r ?? "NOJS"
    }

    /// One step per call. Returns a short state word.
    private static let script = #"""
    function (phase, note, keys) {
      var href = location.href;
      var body = ((document.body && document.body.innerText) || '').toLowerCase();
      if (/checkpoint|authwall|\/login|uas\/|challenge/.test(href)) return 'BLOCKED:LinkedIn wants you to sign in or pass a check';
      if (body.indexOf('security verification') >= 0 || body.indexOf('captcha') >= 0 || body.indexOf('quick security check') >= 0)
        return 'BLOCKED:LinkedIn showed a security check';
      if (body.indexOf('weekly invitation limit') >= 0 || body.indexOf('reached the weekly') >= 0) return 'BLOCKED:weekly invitation limit reached';
      if (body.indexOf('restricted') >= 0 && body.indexOf('account') >= 0 && body.indexOf('temporarily') >= 0) return 'BLOCKED:LinkedIn account warning';
      function vis(e) { return e && e.offsetParent !== null; }
      function all(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)).filter(vis); }
      function btns(root) { return all(root, 'button, [role=button], [role=menuitem], a'); }
      function label(e) { return (((e.getAttribute('aria-label') || '') + ' ' + (e.innerText || '')).trim()).toLowerCase(); }
      function text(e) { return ((e.innerText || '').trim()).toLowerCase(); }
      var main = document.querySelector('main');
      var top = main ? (main.querySelector('section') || main) : null;
      var modal = all(document, '[role=dialog]')[0] || null;
      if (phase === 'check') {
        if (!top || !top.querySelector('h1')) return 'LOADING';
        var t = (top.innerText || '').toLowerCase();
        if (keys.length && !keys.some(function (k) { return t.indexOf(k) >= 0; })) return 'NOMATCH';
        if (btns(top).some(function (e) { var l = label(e); return l.indexOf('pending') >= 0 || l.indexOf('withdraw') >= 0; })) return 'PENDING';
        if (/(^|\W)1st(\W|$)/.test(t)) return 'CONNECTED';
        return 'READY';
      }
      if (phase === 'connect') {
        var c = btns(top).filter(function (e) { var l = label(e); return (l.indexOf('invite') >= 0 && l.indexOf('connect') >= 0) || text(e) === 'connect'; })[0];
        if (c) { c.click(); return 'CLICKED'; }
        var more = btns(top).filter(function (e) { var l = label(e); return l.indexOf('more actions') >= 0 || text(e) === 'more'; })[0];
        if (more) { more.click(); return 'MORE'; }
        return 'NOCONNECT';
      }
      if (phase === 'menu') {
        var m = btns(document).filter(function (e) {
          var l = label(e);
          return !(top && top.contains(e) && e.tagName === 'BUTTON' && text(e) === 'more') &&
            ((l.indexOf('invite') >= 0 && l.indexOf('connect') >= 0) || text(e) === 'connect');
        })[0];
        if (m) { m.click(); return 'CLICKED'; }
        return 'NOCONNECT';
      }
      if (phase === 'note') {
        if (!modal) return 'WAIT';
        if (modal.querySelector('input[type=email], input[name=email]')) return 'EMAIL';
        var mt = (modal.innerText || '').toLowerCase();
        if (mt.indexOf('premium') >= 0 && (mt.indexOf('personalized') >= 0 || mt.indexOf('note') >= 0) && !modal.querySelector('textarea')) return 'NONOTE';
        if (modal.querySelector('textarea')) return 'TEXTAREA';
        var add = btns(modal).filter(function (e) { return label(e).indexOf('add a note') >= 0; })[0];
        if (add) add.click();
        return 'WAIT';
      }
      if (phase === 'type') {
        var ta = modal && modal.querySelector('textarea');
        if (!ta) return 'NOTEXT';
        var setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
        ta.focus();
        setter.call(ta, note);
        ta.dispatchEvent(new Event('input', { bubbles: true }));
        ta.dispatchEvent(new Event('change', { bubbles: true }));
        return ta.value === note ? 'TYPED' : 'NOTEXT';
      }
      function sendButton() {
        return modal && btns(modal).filter(function (e) {
          var l = label(e);
          return l.indexOf('send') >= 0 && l.indexOf('without') < 0 && !e.disabled && e.getAttribute('aria-disabled') !== 'true';
        })[0];
      }
      if (phase === 'send') {
        var s = sendButton();
        if (!s) return 'WAIT';
        window.__clarityClicked = true;
        s.click();
        return 'CLICKED';
      }
      if (phase === 'watch') {
        var w = sendButton();
        if (w && !w.__clarityWatch) {
          w.__clarityWatch = true;
          w.addEventListener('click', function () { window.__clarityClicked = true; }, true);
        }
        return w ? 'WATCHING' : 'NOSEND';
      }
      if (phase === 'verify') {
        if (modal) {
          var vt = (modal.innerText || '').toLowerCase();
          if (vt.indexOf('limit') >= 0 && vt.indexOf('invitation') >= 0) return 'BLOCKED:invitation limit reached';
          if (modal.querySelector('textarea')) return 'WAIT';
        }
        var pending = top && btns(top).some(function (e) { var l = label(e); return l.indexOf('pending') >= 0 || l.indexOf('withdraw') >= 0; });
        if (window.__clarityClicked || pending) return 'SENT';
        return modal ? 'WAIT' : 'CLOSED';
      }
      if (phase === 'close') {
        if (modal) {
          var x = btns(modal).filter(function (e) { var l = label(e); return l.indexOf('dismiss') >= 0 || l.indexOf('cancel') >= 0; })[0];
          if (x) x.click();
        }
        return 'OK';
      }
      return 'UNKNOWN';
    }
    """#
}
