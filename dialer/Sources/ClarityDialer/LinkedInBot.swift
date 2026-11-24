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
    static let weeklyCap = 100
    static var running = false

    /// Settings: send connection requests automatically on sequence days that have a LinkedIn note.
    static var isOn: Bool { UserDefaults.standard.object(forKey: "linkedInBotOn") as? Bool ?? true }
    /// On: clicks Send itself. Off: types the note and waits for the rep to click Send.
    static var autoSend: Bool { UserDefaults.standard.object(forKey: "linkedInBotSend") as? Bool ?? true }

    static var pausedUntil: Date? {
        get { UserDefaults.standard.object(forKey: "linkedInBotPausedUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "linkedInBotPausedUntil") }
    }

    private static var todayKey: String { "linkedInBotSent-" + Date().formatted(.iso8601.year().month().day()) }
    static var sentToday: Int { UserDefaults.standard.integer(forKey: todayKey) }

    /// Sends in the last 7 days.
    static var sentThisWeek: Int {
        let cal = Calendar.current
        return (0..<7).reduce(0) { sum, back in
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { return sum }
            return sum + UserDefaults.standard.integer(forKey: "linkedInBotSent-" + d.formatted(.iso8601.year().month().day()))
        }
    }

    /// Last send, and a random 1 to 4 minute gap before the next one.
    static var lastSentAt: Date? {
        get { UserDefaults.standard.object(forKey: "linkedInBotLastSent") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "linkedInBotLastSent") }
    }
    static var gap: TimeInterval = .random(in: 60...240)
    /// Steps that failed in a row: two and the bot pauses.
    static var missesInARow = 0

    /// Seconds left before the next request may go out (0 = now).
    static var waitLeft: TimeInterval { lastSentAt.map { max(0, gap - Date().timeIntervalSince($0)) } ?? 0 }

    /// Why the bot won't run right now, or nil if it can.
    static var whyNot: String? {
        if running { return "already busy" }
        if let until = pausedUntil, until > Date() { return "paused until \(until.formatted(date: .omitted, time: .shortened))" }
        let weekday = Calendar.current.component(.weekday, from: Date())
        if weekday == 1 || weekday == 7 { return "off on weekends" }
        if sentToday >= dailyCap { return "hit today's limit of \(dailyCap)" }
        if sentThisWeek >= weeklyCap { return "hit this week's limit of \(weeklyCap)" }
        return nil
    }

    /// The note, trimmed to LinkedIn's 200 characters.
    static func note(_ written: String) -> String {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Test mode: everything up to the typed note, then Cancel. Nothing is sent.
    static var testRun = false

    /// The profile tab left open, and whose it is. Closed when the next person opens or they're skipped.
    static var lastTab: (tab: String, key: String?)?
    static var personKey: String?

    /// Just shows their profile in front (no clicks), for people the bot already handled.
    static func showProfile(_ url: URL, key: String) async {
        guard lastTab?.key != key, openingFor != key, !running else { return }
        openingFor = key
        defer { if openingFor == key { openingFor = nil } }
        guard let opened = await openTab(url), opened != "ERR" else { return }
        lastTab = (String(opened.split(separator: "|")[0]), key)
    }

    /// Closes the last person's LinkedIn tab, unless it's this person's.
    static func closeLast(keeping key: String?) {
        guard let last = lastTab, last.key != key || key == nil else { return }
        lastTab = nil
        Task { await closeTab(last.tab) }
    }

    static func connect(profile: URL, note: String, company: String?, name: String? = nil, onStatus: @escaping (String) -> Void) async -> Result {
        running = true
        defer { running = false }
        // A short random start (1 to 5 s), so it looks human but is done fast, even when the
        // first dial goes straight to voicemail or the number is bad.
        if !testRun { await pause(2, 10) }
        guard let opened = await openTab(profile), !opened.isEmpty, opened != "ERR" else {
            return .skipped(chromeProblem ?? "Chrome didn't open the tab")
        }
        let parts = opened.split(separator: "|").map(String.init)
        let tab = parts[0]
        let backTo = parts.count > 1 ? Int(parts[1]) : nil
        let vanity = profile.pathComponents.drop { $0 != "in" }.dropFirst().first
        let keys = (name ?? "").lowercased().split(separator: " ").map(String.init).filter { $0.count >= 3 }
        let result = await run(tab: tab, note: note, keys: keys, vanity: vanity, onStatus: onStatus) // the profile must be this person
        switch result {
        case .sent:
            UserDefaults.standard.set(sentToday + 1, forKey: todayKey)
            lastSentAt = Date()
            gap = .random(in: 60...240)
            missesInARow = 0
        case .blocked:
            pausedUntil = Date().addingTimeInterval(2 * 3600)
        case .skipped(let why) where !why.contains("already") && !why.contains("someone else") && !why.contains("no LinkedIn"):
            // A step didn't work (page changed, button missing): two in a row and the bot stops for 2 hours.
            missesInARow += 1
            if missesInARow >= 2 {
                pausedUntil = Date().addingTimeInterval(2 * 3600)
                missesInARow = 0
                NSLog("%@", "LinkedIn bot: two misses in a row, paused for 2 hours (\(why))")
            }
        default: break
        }
        // A blocked page stays open so the rep can see it; everything else closes.
        // Leave their profile open (back from the invite page if the bot used it).
        if case .blocked = result {} else {
            let link = profile.absoluteString
            if !link.contains("\""), !link.contains("\\") {
                _ = await apple(onTab(tab, "if (URL of t) does not contain \"/in/\" then set URL of t to \"\(link)\"\n return \"OK\""))
            }
        }
        _ = backTo
        lastTab = (tab, personKey)
        return result
    }

    private static func run(tab: String, note: String, keys: [String], vanity: String?, onStatus: (String) -> Void) async -> Result {
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
        case "LOADING":
            NSLog("%@", "LinkedIn bot page report: \(await step("report"))")
            return .skipped("couldn't find their name on the page (details in the Activity log)")
        case "NOMATCH": return .skipped("the LinkedIn link in Salesforce is someone else's profile (name doesn't match). Fix their LinkedIn field")
        case "PENDING": return .pending
        case "CONNECTED": return .alreadyConnected
        default: break
        }

        // The menu click has failed every time in your logs, so when we have their LinkedIn address we go
        // straight to LinkedIn's own invite page: fewer clicks, faster, and safer for the account.
        var c = "SKIPPED"
        if vanity == nil {
            onStatus("LinkedIn: clicking Connect...")
            await pause(1.5, 3)
            c = await step("connect")
            if c == "MORE" {
                await pause(1, 2)
                c = await step("menu")
            }
            if let b = blocked(c) { return b }
        }
        var n = "WAIT"
        if c == "CLICKED" {
            for _ in 0..<6 {
                await pause(1, 1.8)
                n = await step("note")
                if n != "WAIT" { break }
            }
        }
        // LinkedIn ignored the click, or there's no Connect button: use LinkedIn's own "connect with a note" page.
        if n == "WAIT", let vanity, !vanity.contains("\""), !vanity.contains("\\") {
            NSLog("%@", "LinkedIn bot: opening LinkedIn's invite page for the note")
            onStatus("LinkedIn: opening the invite page...")
            _ = await apple(onTab(tab, "set URL of t to \"https://www.linkedin.com/preload/custom-invite/?vanityName=\(vanity)\"\n return \"OK\""))
            for _ in 0..<12 {
                await pause(1.2, 2)
                n = await step("note")
                if n != "WAIT" { break }
            }
        }
        if let b = blocked(n) { return b }
        switch n {
        case "TEXTAREA": break
        case "EMAIL": _ = await step("close"); return .skipped("LinkedIn wants their email to connect")
        case "NONOTE": _ = await step("close"); return .skipped("no free notes left this month (LinkedIn wants Premium)")
        default:
            NSLog("%@", "LinkedIn bot page report: \(await step("report"))")
            _ = await step("close"); return .skipped("Add a note didn't open (details in the Activity log)")
        }

        onStatus("LinkedIn: typing the note...")
        await pause(1, 2)
        guard await step("type") == "TYPED" else {
            _ = await step("close")
            return .skipped("couldn't type the note")
        }

        if testRun {
            await pause(2, 3)
            _ = await step("close")
            return .skipped("TEST OK: found Connect, opened Add a note and typed the note. Nothing was sent")
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
        try? await Task.sleep(for: .milliseconds(Int(Double.random(in: low...high) * 500)))
    }

    // MARK: Chrome

    private static let queue = DispatchQueue(label: "clarity.linkedin-bot")

    /// The last AppleScript error number (-1743: macOS hasn't allowed this app to control Chrome;
    /// -600: Chrome isn't running and couldn't be opened).
    static var lastAppleError: Int?

    private static func apple(_ source: String) async -> String? {
        await withCheckedContinuation { done in
            queue.async {
                var err: NSDictionary?
                let r = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
                let code = err?[NSAppleScript.errorNumber] as? Int
                Task { @MainActor in lastAppleError = code }
                done.resume(returning: r)
            }
        }
    }

    /// Why Chrome couldn't be used, in plain words, or nil.
    static var chromeProblem: String? {
        switch lastAppleError {
        case -1743?: return "macOS hasn't allowed Clarity Dialer to control Chrome. Turn it on in System Settings > Privacy & Security > Automation > Clarity Dialer > Google Chrome"
        case -600?, -10810?: return "Chrome isn't open (or isn't installed)"
        case let n?: return "Chrome didn't respond (error \(n))"
        case nil: return nil
        }
    }

    /// No LinkedIn link in Salesforce: search LinkedIn for them in Chrome and take the first person
    /// result. The profile is then checked against their name before anything is sent.
    static func findProfile(name: String, company: String) async -> URL? {
        var c = URLComponents(string: "https://www.linkedin.com/search/results/people/")!
        c.queryItems = [URLQueryItem(name: "keywords", value: "\(name) \(company)".trimmingCharacters(in: .whitespaces))]
        guard let search = c.url, let opened = await openTab(search), opened != "ERR",
              let tab = opened.split(separator: "|").first.map(String.init) else { return nil }
        let js = #"(function(){var a=[].slice.call(document.querySelectorAll('a[href*="/in/"]')).map(function(x){return x.href.split('?')[0];}).filter(function(h){return /linkedin\.com\/in\/[^\/]+\/?$/.test(h);});return a.length?a[0]:'NONE';})()"#
        let b64 = Data(js.utf8).base64EncodedString()
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(1))
            let r = await apple(onTab(tab, "return execute t javascript \"eval(atob('\(b64)'))\""))
            if let r, r.hasPrefix("https://"), let url = URL(string: r) { return url }
        }
        return nil
    }

    /// A new tab in the front Chrome window, without taking the rep away from their tab.
    /// Every LinkedIn tab this app opened that may still be open.
    private static var ourTabs: [String] = []
    private static var tabBusy = false
    /// Whose profile is being opened right now (so a second request for them is ignored).
    static var openingFor: String?

    /// Opens one LinkedIn tab. Closes every LinkedIn tab the app opened before, so there's only ever one.
    private static func openTab(_ url: URL) async -> String? {
        let link = url.absoluteString
        guard !link.contains("\""), !link.contains("\\") else { return nil }
        while tabBusy { try? await Task.sleep(for: .milliseconds(100)) } // one tab job at a time
        tabBusy = true
        defer { tabBusy = false }
        for old in ourTabs { await closeTab(old) }
        ourTabs = []
        let r = await apple("""
        tell application "Google Chrome"
            if (count of windows) = 0 then make new window
            set w to window 1
            set oldIndex to active tab index of w
            set t to make new tab at end of tabs of w with properties {URL:"\(link)"}
            set active tab index of w to (count of tabs of w)
            return ((id of t) as text) & "|" & (oldIndex as text)
        end tell
        """)
        if let r, let id = r.split(separator: "|").first, r != "ERR" { ourTabs.append(String(id)) }
        return r
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
      var profileShown = /\| linkedin/i.test(document.title) && !/sign in|log in|security/i.test(document.title);
      if (!profileShown && (body.indexOf('security verification') >= 0 || body.indexOf('captcha') >= 0 || body.indexOf('quick security check') >= 0))
        return 'BLOCKED:LinkedIn showed a security check';
      if (body.indexOf('weekly invitation limit') >= 0 || body.indexOf('reached the weekly') >= 0) return 'BLOCKED:weekly invitation limit reached';
      if (body.indexOf('restricted') >= 0 && body.indexOf('account') >= 0 && body.indexOf('temporarily') >= 0) return 'BLOCKED:LinkedIn account warning';
      function vis(e) { return e && e.offsetParent !== null; }
      function all(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)).filter(vis); }
      function btns(root) { return all(root, 'button, [role=button], [role=menuitem], a'); }
      function label(e) { return (((e.getAttribute('aria-label') || '') + ' ' + (e.innerText || '')).trim()).toLowerCase(); }
      function text(e) { return ((e.innerText || '').trim()).toLowerCase(); }
      var main = document.querySelector('main') || document.body;
      // Their name: the page's h1, wherever LinkedIn puts it this month.
      var h1 = all(document, 'h1')[0] || all(document, '.text-heading-xlarge')[0] || null;
      if (!h1) {
        // No heading on the new layout: their name is the page title ("Jane Doe | LinkedIn").
        var name = (document.title || '').split('|')[0].replace(/^\(\d+\)\s*/, '').trim().toLowerCase();
        if (name.length > 2) {
          var hits = all(main, 'h1, h2, h3, span, div, p, a').filter(function (e) {
            return (e.innerText || '').trim().toLowerCase() === name;
          });
          h1 = hits[0] || null;
        }
      }
      // The top card: the nearest box around the name that also holds the action buttons.
      var top = null;
      if (h1) {
        var box = h1;
        for (var up = 0; up < 12 && box && box !== document.body; up++) {
          box = box.parentElement;
          if (box && btns(box).some(function (e) { var l = label(e); return l.indexOf('more') >= 0 || l.indexOf('connect') >= 0 || l.indexOf('message') >= 0 || l.indexOf('follow') >= 0; })) { top = box; break; }
        }
        if (!top) top = h1.closest('section') || main;
      }
      var modal = all(document, '[role=dialog], dialog[open], [aria-modal=true], .artdeco-modal, .artdeco-modal-overlay')[0] || null;
      // The new layout may not mark its pop-up as a dialog: use the whole page, but only for the pop-up's own controls.
      var scope = modal || document;
      if (phase === 'report') {
        return 'url=' + href.slice(0, 80) + ' title=' + document.title.slice(0, 60) + ' h1s=' + document.querySelectorAll('h1').length +
          ' main=' + !!document.querySelector('main') + ' ready=' + document.readyState + ' top=' + !!top +
          ' modal=' + !!modal + ' textareas=' + all(document, 'textarea').length +
          ' popup=' + btns(scope).filter(function (e) { return !(top && top.contains(e)); }).slice(0, 14).map(function (e) { return label(e).slice(0, 30); }).join(' | ') +
          ' buttons=' + (top ? btns(top) : btns(document)).slice(0, 12).map(function (e) { return label(e).slice(0, 30); }).join(' | ');
      }
      if (phase === 'check') {
        if (!top || !h1) return 'LOADING';
        var t = ((top.innerText || '') + ' ' + document.title).toLowerCase();
        if (keys.length && !keys.some(function (k) { return t.indexOf(k) >= 0; })) return 'NOMATCH';
        if (btns(top).some(function (e) { var l = label(e); return l.indexOf('pending') >= 0 || l.indexOf('withdraw') >= 0; })) return 'PENDING';
        if (/(^|\W)1st(\W|$)/.test(t)) return 'CONNECTED';
        return 'READY';
      }
      if (phase === 'connect') {
        var c = btns(top).filter(function (e) { var l = label(e); return (l.indexOf('invite') >= 0 && l.indexOf('connect') >= 0) || text(e) === 'connect'; })[0];
        if (c) { c.click(); return 'CLICKED'; }
        var tb = btns(top);
        var more = tb.filter(function (e) { var l = label(e); return l.indexOf('more') >= 0 || /^(…|\.\.\.)$/.test(text(e)); })[0];
        if (!more) {
          // An icon-only button right after Message is the "…" menu.
          var mi = tb.findIndex(function (e) { return label(e).indexOf('message') >= 0; });
          more = mi >= 0 ? tb.slice(mi + 1).filter(function (e) { return e.tagName === 'BUTTON' && text(e) === ''; })[0] : null;
        }
        if (more) { var r = more.getBoundingClientRect(); window.__clarityMore = { x: r.left, y: r.bottom }; more.click(); return 'MORE'; }
        return 'NOCONNECT';
      }
      if (phase === 'menu') {
        // The "Connect" item closest to the "…" button just clicked (never one from the sidebar).
        var at = window.__clarityMore || { x: 0, y: 0 };
        var m = null, best = 1e9;
        all(document, 'button, [role=button], [role=menuitem], a, li, div, span').forEach(function (e) {
          var l = label(e);
          if (!(text(e) === 'connect' || (l.indexOf('invite') >= 0 && l.indexOf('connect') >= 0))) return;
          var r = e.getBoundingClientRect();
          var d = Math.abs(r.left - at.x) + Math.abs(r.top - at.y);
          if (d < best && d < 500) { best = d; m = e; }
        });
        if (m) { m.click(); return 'CLICKED'; }
        return 'NOCONNECT';
      }
      if (phase === 'note') {
        if (scope.querySelector('input[type=email], input[name=email]') && !all(scope, 'textarea')[0]) return 'EMAIL';
        if (all(scope, 'textarea')[0]) return 'TEXTAREA';
        var add = btns(scope).filter(function (e) { return label(e).indexOf('add a note') >= 0; })[0];
        if (add && !add.__clarityTried) { add.__clarityTried = true; add.click(); return 'WAIT'; }
        var mt = ((modal || document.body).innerText || '').toLowerCase();
        if (add === undefined && mt.indexOf('premium') >= 0 && mt.indexOf('personalize') >= 0) return 'NONOTE';
        return 'WAIT';
      }
      if (phase === 'type') {
        var ta = all(scope, 'textarea')[0];
        if (!ta) return 'NOTEXT';
        var setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
        ta.focus();
        setter.call(ta, note);
        ta.dispatchEvent(new Event('input', { bubbles: true }));
        ta.dispatchEvent(new Event('change', { bubbles: true }));
        return ta.value === note ? 'TYPED' : 'NOTEXT';
      }
      function sendButton() {
        return btns(scope).filter(function (e) {
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
        var vt = ((modal || document.body).innerText || '').toLowerCase();
        if (vt.indexOf('invitation limit') >= 0 || vt.indexOf('weekly limit') >= 0) return 'BLOCKED:invitation limit reached';
        if (all(scope, 'textarea')[0]) return 'WAIT';
        var pending = top && btns(top).some(function (e) { var l = label(e); return l.indexOf('pending') >= 0 || l.indexOf('withdraw') >= 0; });
        if (window.__clarityClicked || pending) return 'SENT';
        return 'CLOSED';
      }
      if (phase === 'close') {
        var x = btns(scope).filter(function (e) { var l = label(e); return l.indexOf('dismiss') >= 0 || l.indexOf('cancel') >= 0 || l.indexOf('close') >= 0; })[0];
        if (x) x.click();
        return 'OK';
      }
      return 'UNKNOWN';
    }
    """#
}
