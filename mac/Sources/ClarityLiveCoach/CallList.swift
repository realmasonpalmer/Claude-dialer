import AppKit

/// Knows the rep's Salesforce call list: the order, where they are, who's been called today,
/// and who to call next. Reads the Salesforce tab in Chrome (not Salesforce itself).
///
/// Built to be reliable in Lightning:
/// - finds the Salesforce tab even when another tab (like LinkedIn) is in front
/// - looks inside Salesforce's sealed components (shadow DOM), where list rows live
/// - only reads the list area: the split view panel or the list view page, never related lists
/// - ignores hidden pages Salesforce keeps loaded in the background
@MainActor
final class CallList: ObservableObject {
    struct Record: Codable, Equatable {
        let id: String
        let name: String
        let url: String
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var message: String?
    /// Who "Next" will open (refreshed every couple of seconds; reading Chrome is too slow for every redraw).
    @Published private(set) var upNextInfo: (name: String, position: Int)?
    /// Chrome won't let the app read the page (its "Allow JavaScript from Apple Events" setting is off).
    @Published private(set) var chromeBlocked = false
    /// Records called today, by Salesforce ID (shared with the Salesforce list, see `CalledToday`).
    @Published private(set) var calledToday: Set<String> = []

    private var lastIndex: Int
    private var lastCapture = Date.distantPast

    enum State: Equatable {
        case needsChromeSetting
        case needsList
        case ready(name: String, position: Int, total: Int)
        case endOfList
    }

    var state: State {
        if chromeBlocked { return .needsChromeSetting }
        if records.isEmpty { return .needsList }
        if let next = upNextInfo { return .ready(name: next.name, position: next.position, total: records.count) }
        return .endOfList
    }

    /// How many on this list haven't been called today.
    var leftToCall: Int { records.filter { CalledToday.isCallable($0.id) }.count }
    /// On the plan but not due today: they come back on a later call day.
    var comingBackLater: Int { records.filter { Cadence.comesBackLater($0.id) }.count }
    /// Due today, but in a time zone the rep isn't calling right now.
    var heldByTimeZone: Int { TimeZoneFilter.heldBack(records.map(\.id)) }

    init() {
        let d = UserDefaults.standard
        lastIndex = d.object(forKey: PrefKey.callListIndex) as? Int ?? -1
        if let data = d.data(forKey: PrefKey.callList), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
        listKey = d.data(forKey: PrefKey.callListKey).flatMap { try? JSONDecoder().decode(ListKey.self, from: $0) }
        resetCalledIfNewDay()
    }

    // MARK: Learning the list

    /// Reads the list from the Salesforce tab (split view panel or list view page). Every few seconds.
    func captureIfListView() {
        guard Date().timeIntervalSince(lastCapture) > 3 else { return }
        lastCapture = Date()
        switch SalesforceChrome.readList() {
        case .blocked:
            if !chromeBlocked { chromeBlocked = true }
        case .noSalesforceTab, .noList:
            if chromeBlocked { chromeBlocked = false }
        case .list(let found):
            if chromeBlocked { chromeBlocked = false }
            guard !found.isEmpty else { return }
            // Which list is this? (From the address bar while the list page shows.)
            let key = SalesforceChrome.url().flatMap(Self.listKey)
            if let key, key != listKey {
                // A different list: start over with what's on screen, then load all of it from Salesforce.
                listKey = key
                records = found
                lastIndex = -1
                fullListKey = nil
                message = nil
                save()
                Task { await loadFullList() }
                return
            }
            // Same list. If the screen shows people the saved list doesn't have, or in a different
            // order, the list changed in Salesforce (new filters or sort): reload it.
            let known = Set(records.map(\.id))
            let added = found.filter { !known.contains($0.id) }
            if !added.isEmpty || !Self.sameOrder(found, records) {
                if Salesforce.isConnected, listKey != nil { Task { await refreshFromSalesforce() } }
            } else if Date().timeIntervalSince(lastFullLoad) > 120, listKey != nil {
                // Pick up filter changes that don't show on screen yet (every 2 minutes).
                Task { await refreshFromSalesforce() }
            }
            // Meanwhile (or with no Salesforce connection), add who's on screen.
            guard !added.isEmpty || records.isEmpty else { return }
            records += added
            message = nil
            save()
        }
    }

    /// True if the rows on screen appear in the saved list in the same order.
    static func sameOrder(_ screen: [Record], _ saved: [Record]) -> Bool {
        var last = -1
        for r in screen {
            guard let i = saved.firstIndex(where: { $0.id.prefix(15) == r.id.prefix(15) }) else { return false }
            if i < last { return false }
            last = i
        }
        return true
    }

    private var lastFullLoad = Date.distantPast
    private var lastRefreshTry = Date.distantPast

    /// Reloads the whole list from Salesforce so it matches the list's current filters and sort.
    /// At most every 30 seconds. Returns true if it learned new people.
    @discardableResult
    func refreshFromSalesforce(force: Bool = false) async -> Bool {
        guard Salesforce.isConnected, force || Date().timeIntervalSince(lastRefreshTry) > 30 else { return false }
        lastRefreshTry = Date()
        fullListKey = nil
        return await loadFullList()
    }

    /// The list on screen (object + list view), from an address like /lightning/o/Contact/list?filterName=00B...
    @Published private(set) var listKey: ListKey?
    private var fullListKey: ListKey?

    struct ListKey: Equatable, Codable {
        let object: String
        let view: String
    }

    static func listKey(from url: String) -> ListKey? {
        guard let o = url.range(of: "/lightning/o/") else { return nil }
        let object = url[o.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        guard ["Lead", "Contact"].contains(object),
              let comps = URLComponents(string: url),
              let view = comps.queryItems?.first(where: { $0.name == "filterName" })?.value, !view.isEmpty else { return nil }
        return ListKey(object: object, view: view)
    }

    /// Loads everyone on the list straight from Salesforce (up to 2,000), not just the rows on screen.
    /// Keeps the person we're on. Returns true if it learned new people.
    @discardableResult
    func loadFullList() async -> Bool {
        guard Salesforce.isConnected, let key = listKey, fullListKey != key else { return false }
        do {
            let rows = try await Salesforce.fullList(object: key.object, key: key.view)
            guard !rows.isEmpty, listKey == key else { return false }
            // Time zones first, so the time zone filter is right before anyone is opened.
            await TimeZoneFilter.load(ids: rows.map(\.id), object: key.object)
            // The team's calls from Salesforce, so the order knows who was called on another Mac.
            await CallHistory.load(ids: rows.map(\.id), object: key.object)
            guard listKey == key else { return false }
            let origin = SalesforceChrome.url().flatMap { URL(string: $0) }.flatMap { u in u.host.map { "https://\($0)" } } ?? ""
            let currentID = lastIndex >= 0 && lastIndex < records.count ? records[lastIndex].id : nil
            let before = Set(records.map { String($0.id.prefix(15)) })
            let beforeCount = records.count
            var fresh = rows.map { Record(id: $0.id, name: $0.name, url: "\(origin)/lightning/r/\(key.object)/\($0.id)/view") }
            // The screen is the truth for order (a sort picked in Salesforce may not reach the API):
            // people on screen go first, in screen order; everyone else follows in Salesforce's order.
            if case .list(let screen) = SalesforceChrome.readList(), !Self.sameOrder(screen, fresh) {
                let onScreen = screen.map { String($0.id.prefix(15)) }
                let byID = Dictionary(fresh.map { (String($0.id.prefix(15)), $0) }, uniquingKeysWith: { a, _ in a })
                let top = onScreen.compactMap { byID[$0] }
                let topIDs = Set(top.map { String($0.id.prefix(15)) })
                fresh = top + fresh.filter { !topIDs.contains(String($0.id.prefix(15))) }
            }
            records = fresh
            lastFullLoad = Date()
            if let currentID, let i = records.firstIndex(where: { $0.id.prefix(15) == currentID.prefix(15) }) {
                lastIndex = i
            } else if currentID != nil {
                lastIndex = -1 // the person we were on was filtered off: start from the top
            }
            fullListKey = key
            save()
            refreshUpNext()
            let newCount = records.filter { !before.contains(String($0.id.prefix(15))) }.count
            let dropped = before.subtracting(records.map { String($0.id.prefix(15)) }).count
            if records.count != beforeCount || newCount > 0 || dropped > 0 {
                ActivityLog.add("List: loaded \(records.count) people from Salesforce (\(newCount) new, \(dropped) filtered off)")
            }
            return newCount > 0
        } catch {
            ActivityLog.problem("List: couldn't load the full list from Salesforce: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Where we are and who's next

    /// The record open in the Salesforce tab right now, if it's on the list.
    func currentIndex() -> Int? {
        if let url = SalesforceChrome.url(), let id = Self.recordID(from: url),
           let i = records.firstIndex(where: { $0.id == id }) {
            return i
        }
        // Some split views keep the list address; fall back to the name in the tab title.
        if let title = SalesforceChrome.title(), let name = title.components(separatedBy: " | ").first {
            let matches = records.indices.filter { records[$0].name == name }
            return matches.first { $0 > lastIndex } ?? matches.first
        }
        return nil
    }

    /// Who to call next: the highest priority person on the list (late follow-ups, then due
    /// follow-ups, then new people, by last name; see `CallQueue`), not counting the one open now.
    /// Someone the rep moved past today without calling goes after everyone else.
    func upNext(after index: Int? = nil) -> (record: Record, position: Int)? {
        guard !records.isEmpty else { return nil }
        let from = index ?? currentIndex() ?? lastIndex
        let openID = records.indices.contains(from) ? records[from].id : nil
        var best: (key: (Int, Int, Int, Int, String, String), index: Int)?
        for i in records.indices {
            let r = records[i]
            guard r.id != openID, CalledToday.isCallable(r.id) else { continue }
            let k = CallQueue.key(id: r.id, name: r.name, passedOver: passedOver.contains(r.id))
            if best == nil || k < best!.key { best = (k, i) }
        }
        return best.map { (records[$0.index], $0.index + 1) }
    }

    /// People the rep moved past today without calling (so Next doesn't keep bringing them back).
    private var passedOver: Set<String> = []
    private var passedDay = ""

    /// Scrolls the Salesforce list so it loads more rows, then reads them. True if new people showed up.
    func loadMore() async -> Bool {
        // Best: ask Salesforce for the whole list.
        if Salesforce.isConnected, listKey != nil {
            fullListKey = nil
            if await loadFullList() { return true }
        }
        let before = records.count
        _ = SalesforceChrome.scrollListToBottom()
        try? await Task.sleep(for: .milliseconds(1500))
        lastCapture = .distantPast
        captureIfListView()
        if records.count > before {
            refreshUpNext()
            return true
        }
        return false
    }

    private var companyNames: [String: String] = [:]
    private var lookingUp: Set<String> = []

    /// The name to show. "Unknown Unknown" placeholders show the company instead (looked up once).
    private func displayName(for record: Record) -> String {
        guard Salesforce.isPlaceholderName(record.name) else { return record.name }
        if let company = companyNames[record.id] { return company }
        let object = record.id.hasPrefix("00Q") ? "Lead" : "Contact"
        if Salesforce.isConnected, !lookingUp.contains(record.id) {
            lookingUp.insert(record.id)
            Task {
                if let d = try? await Salesforce.details(id: record.id, object: object),
                   let company = d.company, !company.isEmpty {
                    companyNames[record.id] = company
                    refreshUpNext()
                }
            }
        }
        return record.name
    }

    /// "Today: 3 late · 12 follow-ups due · 30 new · 8 resting".
    @Published private(set) var summary: String?
    private var summaryAt = Date.distantPast

    func refreshUpNext(after index: Int? = nil) {
        resetCalledIfNewDay()
        // Counting the whole list is the slow part: every 10 seconds is plenty.
        if Date().timeIntervalSince(summaryAt) > 10 {
            summaryAt = Date()
            let s = CallQueue.summary(records.map(\.id))
            if s != summary { summary = s }
        }
        let info = upNext(after: index).map { (name: displayName(for: $0.record), position: $0.position) }
        if info?.name != upNextInfo?.name || info?.position != upNextInfo?.position { upNextInfo = info }
    }

    // MARK: Moving

    /// Opens the next lead that hasn't been called today.
    @discardableResult
    func openNext() -> Bool {
        guard !records.isEmpty else {
            message = "Open your lead list in Salesforce first."
            return false
        }
        guard let (record, position) = upNext() else {
            message = "Nobody else on this list is due today."
            return false
        }
        // The person open now wasn't called: they go to the back for today.
        let today = Date().formatted(.iso8601.year().month().day())
        if passedDay != today { passedDay = today; passedOver = [] }
        if let openID = currentIndex().map({ records[$0].id }) ?? lastOpenedID,
           openID != record.id, !CalledToday.ids.contains(openID) {
            passedOver.insert(openID)
        }
        return open(record, at: position - 1)
    }

    /// Opens the lead before the one open now (called or not).
    @discardableResult
    func openPrevious() -> Bool {
        guard !records.isEmpty else { return false }
        let from = currentIndex() ?? (lastIndex + 1)
        let previous = from - 1
        guard previous >= 0, previous < records.count else { return false }
        return open(records[previous], at: previous)
    }

    /// The record Next or Back opened last (to know when its page has loaded).
    private(set) var lastOpenedID: String?

    private func open(_ record: Record, at index: Int) -> Bool {
        // Click it in the list like the rep would (keeps split view); else go to its address.
        guard SalesforceChrome.click(recordID: record.id) || SalesforceChrome.open(record.url) else {
            message = chromeBlocked
                ? "Chrome needs one setting: View > Developer > Allow JavaScript from Apple Events."
                : "Couldn't find your Salesforce tab in Chrome."
            return false
        }
        lastIndex = index
        lastOpenedID = record.id
        message = nil
        save()
        // The page hasn't changed yet, so count from the one just opened (not the page on screen).
        refreshUpNext(after: index)
        return true
    }

    /// Everything the app sees about the list, for troubleshooting. No lead details beyond names.
    func debugReport() -> String {
        let url = SalesforceChrome.url() ?? "(no Salesforce tab found)"
        let title = SalesforceChrome.title() ?? "(none)"
        let result: String
        switch SalesforceChrome.readList() {
        case .blocked: result = "blocked (Chrome setting off, or the page script failed)"
        case .noSalesforceTab: result = "no Salesforce tab"
        case .noList: result = "no list on screen"
        case .list(let found): result = "\(found.count) records on screen, first: \(found.prefix(3).map(\.name).joined(separator: ", "))"
        }
        return """
        Clarity Live Coach - Next debug
        Tab address: \(url)
        Tab title: \(title)
        List on screen: \(result)
        Saved list: \(records.count) records, first: \(records.prefix(3).map(\.name).joined(separator: ", "))
        Current position: \(currentIndex().map { String($0 + 1) } ?? "not found") (last opened: \(lastIndex + 1))
        Up next: \(upNext().map { "\($0.record.name) at \($0.position)" } ?? "none")
        Called today: \(calledToday.count)
        Chrome blocked: \(chromeBlocked)
        """
    }

    // MARK: Called today

    /// Called when a call connects on the record that's open.
    func markCurrentCalled() {
        resetCalledIfNewDay()
        guard let i = currentIndex() else { return }
        lastIndex = i
        CalledToday.add(records[i].id)
        calledToday = CalledToday.ids
        save()
        refreshUpNext()
    }

    func clearCalledToday() {
        CalledToday.clear()
        calledToday = CalledToday.ids
        save()
        refreshUpNext()
    }

    private func resetCalledIfNewDay() {
        CalledToday.resetIfNewDay()
        if calledToday != CalledToday.ids { calledToday = CalledToday.ids }
    }

    static func recordID(from url: String) -> String? {
        guard let r = url.range(of: "/lightning/r/") else { return nil }
        let parts = url[r.upperBound...].split(separator: "/").map(String.init)
        // /lightning/r/Lead/00Q.../view  or  /lightning/r/00Q.../view
        let id = parts.count > 2 && parts[2].hasPrefix("view") ? parts[1] : parts.first
        return id.flatMap { $0.count >= 15 ? String($0.prefix(18)) : nil }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(lastIndex, forKey: PrefKey.callListIndex)
        if let data = try? JSONEncoder().encode(records) { d.set(data, forKey: PrefKey.callList) }
        if let listKey, let data = try? JSONEncoder().encode(listKey) { d.set(data, forKey: PrefKey.callListKey) }
    }
}

/// Talks to the Salesforce tab in Chrome, wherever it is (not just the tab in front).
enum SalesforceChrome {
    enum ListResult {
        case list([CallList.Record])
        case noList
        case noSalesforceTab
        case blocked
    }

    private static var chromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    // MARK: Snapshot (address + title), kept fresh off the main thread

    /// Every AppleScript runs on this one queue, never two at once. The main thread only waits
    /// for actions (open, click, JavaScript) and for "live" reads; plain reads use the snapshot.
    private static let queue = DispatchQueue(label: "SalesforceChrome", qos: .userInitiated)
    private static let lock = NSLock()
    private static var snapshot: (at: Date, url: String?, title: String?)?
    private static var watching = false
    /// How old the snapshot may be for a plain read. It's refreshed every half second.
    private static let maxAge: TimeInterval = 1.0

    private static func startWatching() {
        lock.lock(); defer { lock.unlock() }
        guard !watching else { return }
        watching = true
        queue.async { refreshLoop() }
    }

    private static func refreshLoop() {
        _ = takeSnapshot()
        queue.asyncAfter(deadline: .now() + 0.5) { refreshLoop() }
    }

    /// Reads the address and title in one AppleScript. Runs on `queue`.
    private static func takeSnapshot() -> (url: String?, title: String?) {
        let r = runNow("return (URL of theTab) & linefeed & (title of theTab)")
        var url: String?, title: String?
        if let r, r != "NOSF" {
            let parts = r.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            url = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            title = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        }
        lock.lock(); snapshot = (Date(), url, title); lock.unlock()
        return (url, title)
    }

    /// The snapshot if it's fresh enough, else a live read.
    private static func current(live: Bool) -> (url: String?, title: String?) {
        startWatching()
        if !live {
            lock.lock(); let s = snapshot; lock.unlock()
            if let s, Date().timeIntervalSince(s.at) < maxAge { return (s.url, s.title) }
        }
        return queue.sync { takeSnapshot() }
    }

    /// After the app changes the page, plain reads wait for a new snapshot.
    private static func invalidate() {
        lock.lock(); snapshot = nil; lock.unlock()
    }

    /// Runs an AppleScript action on the AppleScript queue (waits for it).
    private static func run(_ action: String) -> String? {
        queue.sync { runNow(action) }
    }

    /// Runs an AppleScript action against the Salesforce tab. The action uses `theTab`
    /// (and `theWindow`, `theIndex`). Prefers a Salesforce tab that's showing; else the first one found.
    /// Returns "NOSF" if no Salesforce tab is open, nil if the script failed. Only call on `queue`.
    private static func runNow(_ action: String) -> String? {
        guard chromeRunning else { return nil }
        let source = """
        tell application "Google Chrome"
            set theTab to missing value
            set theWindow to missing value
            set theIndex to 0
            repeat with w in windows
                if (URL of active tab of w) contains ".force.com" then
                    set theTab to active tab of w
                    set theWindow to w
                    set theIndex to active tab index of w
                    exit repeat
                end if
            end repeat
            if theTab is missing value then
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if (URL of t) contains ".force.com" then
                            set theTab to t
                            set theWindow to w
                            set theIndex to i
                            exit repeat
                        end if
                    end repeat
                    if theTab is not missing value then exit repeat
                end repeat
            end if
            if theTab is missing value then return "NOSF"
            \(action)
        end tell
        """
        return NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue
    }

    /// The Salesforce tab's address. `live` reads Chrome now (for checks right before acting);
    /// otherwise the background snapshot (at most a second old) is used.
    static func url(live: Bool = false) -> String? { current(live: live).url }

    static func title(live: Bool = false) -> String? { current(live: live).title }

    /// Runs JavaScript in the Salesforce tab. nil if Chrome blocks it or there's no Salesforce tab.
    static func javascript(_ js: String) -> String? {
        guard !js.contains("\""), !js.contains("\\") else { return nil } // keep the script safe to embed
        guard let r = run("return execute theTab javascript \"\(js)\""), r != "NOSF" else { return nil }
        return r
    }

    /// Shows the Salesforce tab and goes to an address.
    static func open(_ url: String) -> Bool {
        guard url.hasPrefix("https://"), !url.contains("\"") else { return false }
        defer { invalidate() }
        return run("""
        set URL of theTab to "\(url)"
        set active tab index of theWindow to theIndex
        set index of theWindow to 1
        return "ok"
        """) == "ok"
    }

    /// Clicks the record's link in the list (split view or table view) and shows the tab.
    static func click(recordID: String) -> Bool {
        guard recordID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let js = deepFind + "(function(){var links=deep(listRoot()||document,'a[href]',[]);"
            + "for(var i=0;i<links.length;i++){var a=links[i];"
            + "if(a.getClientRects().length&&a.href.indexOf('\(recordID)')>=0&&(a.textContent||'').trim()){a.click();return 'ok';}}"
            + "return 'no';})()"
        guard javascript(js) == "ok" else { return false }
        defer { invalidate() }
        _ = run("""
        set active tab index of theWindow to theIndex
        set index of theWindow to 1
        return "ok"
        """)
        return true
    }

    /// Clicks the number on the open record (Salesforce's click-to-dial): Mobile, or Phone if there's
    /// no Mobile. That makes the Aircall panel in Salesforce dial it. Only a fallback when the app
    /// can't place calls itself. Skips the split view list.
    static func clickToDial() -> Bool {
        for which in [mobileLabel, phoneLabel] {
            if javascript(mobileFinder + "(function(){var el=numberEl(\(which));if(!el)return 'no';"
                + "var t=(el.shadowRoot||el).querySelector('a,button');if(t){t.click();return 'ok';}return 'no';})()") == "ok" {
                return true
            }
        }
        return false
    }

    /// The number to call: Mobile, or the Phone field when there's no Mobile.
    static func dialNumber() -> String? { mobileNumber() ?? number(labeled: phoneLabel) }

    /// The Mobile number on the open record (texts only ever go here).
    static func mobileNumber() -> String? { number(labeled: mobileLabel) }

    /// Field labels, as JavaScript regexes. "Phone" means exactly the Phone field, not Home/Other Phone.
    private static let mobileLabel = "/mobile/i"
    private static let phoneLabel = "/^[ *]*phone[ *]*$/i" // no backslashes: the script can't carry them

    /// A number field on the open record, found by its label. Works when click-to-dial is on, and
    /// when it's off (the crossed-out phone icon), since Salesforce draws the number differently then.
    /// Last resort: the field's own text.
    private static func number(labeled which: String) -> String? {
        let raw = javascript(mobileFinder
            + "function allText(n){if(!n)return '';var s=n.textContent||'';"
            + "var all=n.querySelectorAll?n.querySelectorAll('*'):[];"
            + "for(var i=0;i<all.length;i++){if(all[i].shadowRoot)s+=' '+allText(all[i].shadowRoot);}"
            + "if(n.shadowRoot)s+=' '+allText(n.shadowRoot);return s;}"
            + "(function(){var el=numberEl(\(which));if(el){"
            + "var v=el.value||el.getAttribute('value');if(v)return String(v);"
            + "var t=allText(el).trim();if(t)return t;}"
            + "var lr=listRoot(),items=deep(document,'[field-label]',[]);"
            + "for(var i=0;i<items.length;i++){var it=items[i];"
            + "if(!it.getClientRects().length||(lr&&inside(it,lr)))continue;"
            + "if(\(which).test(it.getAttribute('field-label')))return allText(it);}"
            + "return '';})()")
        guard let raw else { return nil }
        // Pull just the phone number out of the text.
        let pattern = #"(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}"#
        guard let r = raw.range(of: pattern, options: .regularExpression) else { return nil }
        return String(raw[r])
    }

    /// JavaScript: numberEl(re) finds the click-to-dial number whose field label matches re.
    /// label() walks up from a number to the nearest field label ("Mobile", "Phone", ...).
    private static let mobileFinder = deepFind
        + "function inside(n,r){while(n){if(n===r)return true;n=n.parentNode||n.host;}return false;}"
        + "function txt(e){return e?((e.getAttribute&&e.getAttribute('title'))||e.innerText||e.textContent||'').trim():'';}"
        + "function label(n){for(var k=0;n&&k<12;k++){"
        + "var f=n.getAttribute&&n.getAttribute('field-label');if(f)return f;"
        + "var rs=[n,n.shadowRoot];for(var r=0;r<2;r++){var x=rs[r];if(!x||!x.querySelector)continue;"
        + "var l=x.querySelector('.test-id__field-label,.slds-form-element__label,p.slds-text-title');"
        + "if(l&&txt(l))return txt(l);}"
        + "n=n.parentNode||n.host;}return '';}"
        + "function numberEl(re){var lr=listRoot(),els=deep(document,'lightning-click-to-dial,lightning-formatted-phone',[]);"
        + "for(var i=0;i<els.length;i++){var el=els[i];"
        + "if(!el.getClientRects().length||(lr&&inside(el,lr)))continue;"
        + "if(re.test(label(el)))return el;}"
        + "return null;}"

    /// Scrolls the list (split view panel or table) to the bottom so Salesforce loads the next rows.
    @discardableResult
    static func scrollListToBottom() -> Bool {
        let js = deepFind + "(function(){var r=listRoot()||document,els=deep(r,'*',[]),best=null,h=0;"
            + "for(var i=0;i<els.length;i++){var e=els[i];"
            + "if(e.clientHeight>150&&e.scrollHeight>e.clientHeight+40&&e.scrollHeight>h){best=e;h=e.scrollHeight;}}"
            + "if(best){best.scrollTop=best.scrollHeight;return 'ok';}"
            + "window.scrollTo(0,document.body.scrollHeight);return 'page';})()"
        return javascript(js) != nil
    }

    /// The LinkedIn profile link on the open record (Lead "Linkedin" / Contact "LinkedIn" field), if shown.
    static func linkedInProfile() -> String? {
        // Skip links inside the split view list, so a LinkedIn column there can't win over the open record.
        let js = deepFind + "function inside(n,r){while(n){if(n===r)return true;n=n.parentNode||n.host;}return false;}"
            + "(function(){var lr=listRoot(),a=deep(document,'a[href]',[]);"
            + "for(var i=0;i<a.length;i++){if(a[i].getClientRects().length&&a[i].href.indexOf('linkedin.com/in/')>=0"
            + "&&!(lr&&inside(a[i],lr)))return a[i].href;}"
            + "return '';})()"
        guard let r = javascript(js), !r.isEmpty else { return nil }
        return r
    }

    /// The visible list's Lead and Contact rows, in screen order.
    static func readList() -> ListResult {
        guard chromeRunning, let tabURL = url() else { return .noSalesforceTab }
        guard tabURL.contains("lightning") else { return .noList }
        let js = deepFind + "(function(){var root=listRoot();"
            + "var onList=location.href.indexOf('/list')>=0||location.href.indexOf('filterName=')>=0;"
            + "if(!root&&!onList)return JSON.stringify({ok:true,records:[]});"
            + "var anchors=deep(root||document,'a[href]',[]),seen={},out=[];"
            + "for(var k=0;k<anchors.length;k++){var a=anchors[k];"
            + "if(!a.getClientRects().length)continue;"
            + "var h=a.href||'',p=h.indexOf('/lightning/r/');if(p<0)continue;"
            + "var parts=h.substring(p+13).split('/');"
            + "var id=(parts.length>2&&parts[2].indexOf('view')==0)?parts[1]:parts[0];"
            + "var name=((a.getAttribute('title')||a.innerText||a.textContent||'').split(String.fromCharCode(10))[0]||'').trim();"
            + "if(!name||seen[id])continue;"
            + "if(id.indexOf('00Q')!=0&&id.indexOf('003')!=0)continue;"
            + "seen[id]=1;out.push({id:id,name:name,url:h});}"
            + "return JSON.stringify({ok:true,records:out});})()"
        guard let raw = javascript(js) else { return .blocked }
        struct Answer: Decodable { let ok: Bool; let records: [CallList.Record] }
        guard let data = raw.data(using: .utf8), let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            return .blocked
        }
        return answer.records.isEmpty ? .noList : .list(answer.records)
    }

    /// JavaScript helpers: `deep` searches inside Salesforce's sealed components (shadow roots);
    /// `listRoot` finds the visible split view list panel, if there is one.
    /// Single quotes only, so it drops into AppleScript without escaping.
    private static let deepFind = "function deep(root,sel,out){var l=root.querySelectorAll(sel);"
        + "for(var i=0;i<l.length;i++)out.push(l[i]);"
        + "var all=root.querySelectorAll('*');"
        + "for(var j=0;j<all.length;j++){if(all[j].shadowRoot)deep(all[j].shadowRoot,sel,out);}"
        + "return out;}"
        + "function listRoot(){var s=deep(document,'.slds-split-view',[]);"
        + "for(var i=0;i<s.length;i++){if(s[i].getClientRects().length)return s[i];}return null;}"
}
