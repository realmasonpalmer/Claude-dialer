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
    /// Records called today, by Salesforce ID.
    @Published private(set) var calledToday: Set<String> = []

    private var lastIndex: Int
    private var lastCapture = Date.distantPast
    private var calledDay: String

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
    var leftToCall: Int { records.filter { !calledToday.contains($0.id) && !RemovedList.contains($0.id) && !DialHistory.isMaxed($0.id) }.count }

    init() {
        let d = UserDefaults.standard
        lastIndex = d.object(forKey: "callListIndex") as? Int ?? -1
        if let data = d.data(forKey: "callList"), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
        calledDay = d.string(forKey: "calledDay") ?? ""
        calledToday = Set(d.stringArray(forKey: "calledToday") ?? [])
        listKey = d.data(forKey: "callListKey").flatMap { try? JSONDecoder().decode(ListKey.self, from: $0) }
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
            // Same list, scrolled: add anyone new, never drop the people already learned.
            let known = Set(records.map(\.id))
            let added = found.filter { !known.contains($0.id) }
            guard !added.isEmpty || records.isEmpty else { return }
            records += added
            message = nil
            save()
        }
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
            let origin = SalesforceChrome.url().flatMap { URL(string: $0) }.flatMap { u in u.host.map { "https://\($0)" } } ?? ""
            let currentID = lastIndex >= 0 && lastIndex < records.count ? records[lastIndex].id : nil
            let before = Set(records.map { String($0.id.prefix(15)) })
            records = rows.map { Record(id: $0.id, name: $0.name, url: "\(origin)/lightning/r/\(key.object)/\($0.id)/view") }
            if let currentID, let i = records.firstIndex(where: { $0.id.prefix(15) == currentID.prefix(15) }) { lastIndex = i }
            fullListKey = key
            save()
            refreshUpNext()
            let newCount = records.filter { !before.contains(String($0.id.prefix(15))) }.count
            ActivityLog.add("List: loaded \(records.count) people from Salesforce (\(newCount) new)")
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

    /// The next record after the current one that hasn't been called today.
    func upNext(after index: Int? = nil) -> (record: Record, position: Int)? {
        guard !records.isEmpty else { return nil }
        let from = index ?? currentIndex() ?? lastIndex
        func callable(_ r: Record) -> Bool {
            !calledToday.contains(r.id) && !RemovedList.contains(r.id) && !DialHistory.isMaxed(r.id)
        }
        var i = from + 1
        while i < records.count {
            if callable(records[i]) { return (records[i], i + 1) }
            i += 1
        }
        // Nobody below: anyone above who was skipped and not called today?
        var j = 0
        while j < min(max(from, 0), records.count) {
            if callable(records[j]) { return (records[j], j + 1) }
            j += 1
        }
        return nil
    }

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

    func refreshUpNext(after index: Int? = nil) {
        resetCalledIfNewDay()
        let info = upNext(after: index).map { (name: $0.record.name, position: $0.position) }
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
            message = "Everyone left on this list has been called today."
            return false
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
        calledToday.insert(records[i].id)
        save()
        refreshUpNext()
    }

    func clearCalledToday() {
        calledToday = []
        save()
        refreshUpNext()
    }

    private func resetCalledIfNewDay() {
        let today = Date().formatted(.iso8601.year().month().day())
        if calledDay != today {
            calledDay = today
            calledToday = []
            save()
        }
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
        d.set(lastIndex, forKey: "callListIndex")
        if let data = try? JSONEncoder().encode(records) { d.set(data, forKey: "callList") }
        d.set(calledDay, forKey: "calledDay")
        d.set(Array(calledToday), forKey: "calledToday")
        if let listKey, let data = try? JSONEncoder().encode(listKey) { d.set(data, forKey: "callListKey") }
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

    /// Runs an AppleScript action against the Salesforce tab. The action uses `theTab`
    /// (and `theWindow`, `theIndex`). Prefers a Salesforce tab that's showing; else the first one found.
    /// Returns "NOSF" if no Salesforce tab is open, nil if the script failed.
    private static func run(_ action: String) -> String? {
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

    static func url() -> String? {
        guard let r = run("return URL of theTab"), r != "NOSF", !r.isEmpty else { return nil }
        return r
    }

    static func title() -> String? {
        guard let r = run("return title of theTab"), r != "NOSF", !r.isEmpty else { return nil }
        return r
    }

    /// Runs JavaScript in the Salesforce tab. nil if Chrome blocks it or there's no Salesforce tab.
    static func javascript(_ js: String) -> String? {
        guard !js.contains("\""), !js.contains("\\") else { return nil } // keep the script safe to embed
        guard let r = run("return execute theTab javascript \"\(js)\""), r != "NOSF" else { return nil }
        return r
    }

    /// Shows the Salesforce tab and goes to an address.
    static func open(_ url: String) -> Bool {
        guard url.hasPrefix("https://"), !url.contains("\"") else { return false }
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
        _ = run("""
        set active tab index of theWindow to theIndex
        set index of theWindow to 1
        return "ok"
        """)
        return true
    }

    /// Clicks the Mobile number on the open record (Salesforce's click-to-dial), which makes the
    /// Aircall panel in Salesforce dial it. Only a fallback when the app can't place calls itself.
    /// Never clicks the Phone field. Skips the split view list.
    static func clickToDial() -> Bool {
        javascript(mobileFinder + "(function(){var el=mobileEl();if(!el)return 'no';"
            + "var t=(el.shadowRoot||el).querySelector('a,button');if(t){t.click();return 'ok';}return 'no';})()") == "ok"
    }

    /// The Mobile number on the open record, so the app can call it through Aircall. Never the Phone field.
    /// Works when click-to-dial is on, and when it's off (the crossed-out phone icon), since
    /// Salesforce draws the number differently then. Last resort: the "Mobile" field's own text.
    static func mobileNumber() -> String? {
        let raw = javascript(mobileFinder
            + "function allText(n){if(!n)return '';var s=n.textContent||'';"
            + "var all=n.querySelectorAll?n.querySelectorAll('*'):[];"
            + "for(var i=0;i<all.length;i++){if(all[i].shadowRoot)s+=' '+allText(all[i].shadowRoot);}"
            + "if(n.shadowRoot)s+=' '+allText(n.shadowRoot);return s;}"
            + "(function(){var el=mobileEl();if(el){"
            + "var v=el.value||el.getAttribute('value');if(v)return String(v);"
            + "var t=allText(el).trim();if(t)return t;}"
            + "var lr=listRoot(),items=deep(document,'[field-label]',[]);"
            + "for(var i=0;i<items.length;i++){var it=items[i];"
            + "if(!it.getClientRects().length||(lr&&inside(it,lr)))continue;"
            + "if(/mobile/i.test(it.getAttribute('field-label')))return allText(it);}"
            + "return '';})()")
        guard let raw else { return nil }
        // Pull just the phone number out of the text.
        let pattern = #"(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}"#
        guard let r = raw.range(of: pattern, options: .regularExpression) else { return nil }
        return String(raw[r])
    }

    /// JavaScript: mobileEl() finds the click-to-dial number whose field label says Mobile.
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
        + "function mobileEl(){var lr=listRoot(),els=deep(document,'lightning-click-to-dial,lightning-formatted-phone',[]);"
        + "for(var i=0;i<els.length;i++){var el=els[i];"
        + "if(!el.getClientRects().length||(lr&&inside(el,lr)))continue;"
        + "if(/mobile/i.test(label(el)))return el;}"
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
