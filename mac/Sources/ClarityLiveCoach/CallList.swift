import AppKit

/// Remembers the order of leads on the rep's Salesforce list view, so "Next" can open the next one.
/// Works by reading the open Chrome tab (needs Chrome's "Allow JavaScript from Apple Events").
@MainActor
final class CallList: ObservableObject {
    struct Record: Codable, Equatable {
        let id: String
        let name: String
        let url: String
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var message: String?
    /// Who "Next" will open, refreshed every couple of seconds (reading Chrome is too slow to do on every redraw).
    @Published private(set) var upNextInfo: (name: String, position: Int)?
    /// Chrome won't let the app read the page (its "Allow JavaScript from Apple Events" setting is off).
    @Published private(set) var chromeBlocked = false

    /// What the Next button should show.
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
    private var lastIndex: Int
    private var lastCapture = Date.distantPast

    init() {
        lastIndex = UserDefaults.standard.integer(forKey: "callListIndex")
        if let data = UserDefaults.standard.data(forKey: "callList"),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
    }

    /// Learns the list order whenever a Salesforce list is on screen: table view, or the
    /// left panel of split view (where the address is the record, not the list). Checked every few seconds.
    func captureIfListView() {
        guard Date().timeIntervalSince(lastCapture) > 4,
              let url = ChromeTab.url(), url.contains("force.com") else { return }
        lastCapture = Date()
        let onListPage = url.contains("/list") || url.contains("filterName=")
        // Reading the page fails only when Chrome blocks it.
        guard let found = ChromeTab.listRecords() else {
            if !chromeBlocked { chromeBlocked = true }
            return
        }
        if chromeBlocked { chromeBlocked = false }
        // A record page alone shows few leads; a list (or split view's panel) shows many.
        guard found.count >= (onListPage ? 2 : 5) else { return }
        if found != records {
            records = found
            lastIndex = -1
            message = nil
            save()
        }
    }

    func refreshUpNext() {
        let next = upNext()
        let info = next.map { (name: $0.record.name, position: $0.position) }
        if info?.name != upNextInfo?.name || info?.position != upNextInfo?.position { upNextInfo = info }
    }

    /// The record after the one open now (or after the last one opened). nil at the end.
    func upNext() -> (record: Record, position: Int)? {
        guard !records.isEmpty else { return nil }
        let currentID = ChromeTab.url().flatMap(Self.recordID)
        let from = currentID.flatMap { id in records.firstIndex { $0.id == id } } ?? lastIndex
        let next = from + 1
        return next < records.count ? (records[next], next + 1) : nil
    }

    /// Opens the record before the one open now.
    @discardableResult
    func openPrevious() -> Bool {
        guard !records.isEmpty else { return false }
        let currentID = ChromeTab.url().flatMap(Self.recordID)
        let from = currentID.flatMap { id in records.firstIndex { $0.id == id } } ?? (lastIndex + 1)
        let previous = from - 1
        guard previous >= 0, previous < records.count else { return false }
        let record = records[previous]
        guard ChromeTab.click(recordID: record.id) || ChromeTab.open(record.url) else { return false }
        lastIndex = previous
        message = nil
        save()
        refreshUpNext()
        return true
    }

    /// Opens the next record in the active Chrome tab. Returns false with a message if it can't.
    @discardableResult
    func openNext() -> Bool {
        guard !records.isEmpty else {
            message = "Open your lead list in Salesforce once, so Next knows the order."
            return false
        }
        guard let (record, position) = upNext() else {
            message = "That was the last one on your list. Open the list again to keep going."
            return false
        }
        // Click it in the list like the rep would (keeps split view); else go to its address.
        guard ChromeTab.click(recordID: record.id) || ChromeTab.open(record.url) else {
            message = "Couldn't open it. In Chrome, turn on View > Developer > Allow JavaScript from Apple Events."
            return false
        }
        lastIndex = position - 1
        message = nil
        save()
        refreshUpNext()
        return true
    }

    static func recordID(from url: String) -> String? {
        guard let range = url.range(of: #"/lightning/r/(?:[A-Za-z0-9_]+/)?([A-Za-z0-9]{15,18})/view"#, options: .regularExpression) else { return nil }
        let match = String(url[range])
        return match.split(separator: "/").dropLast().last.map(String.init)
    }

    private func save() {
        UserDefaults.standard.set(lastIndex, forKey: "callListIndex")
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: "callList") }
    }
}

/// Small helpers for the active Chrome tab.
enum ChromeTab {
    private static var chromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    private static func run(_ source: String) -> String? {
        guard chromeRunning else { return nil }
        return NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue
    }

    static func url() -> String? {
        run("""
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
        """).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func open(_ url: String) -> Bool {
        guard url.hasPrefix("https://"), !url.contains("\"") else { return false }
        return run("""
        tell application "Google Chrome"
            if (count of windows) is 0 then return "no"
            set URL of active tab of front window to "\(url)"
            return "ok"
        end tell
        """) == "ok"
    }

    /// Clicks the link for this record on the page (split view or table view). False if it isn't on screen.
    static func click(recordID: String) -> Bool {
        guard recordID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let js = "(function(){var links=document.querySelectorAll('a[href*=lightning]');"
            + "for(var i=0;i<links.length;i++){var a=links[i];"
            + "if(a.href.indexOf('\(recordID)')>=0&&(a.textContent||'').trim()){a.click();return 'ok';}}"
            + "return 'no';})()"
        return run("""
        tell application "Google Chrome"
            if (count of windows) is 0 then return "no"
            return execute active tab of front window javascript "\(js)"
        end tell
        """) == "ok"
    }

    /// Record links on a list view, in screen order, without duplicates.
    static func listRecords() -> [CallList.Record]? {
        // Plain JavaScript with single quotes only, so it drops into AppleScript without escaping.
        let js = "JSON.stringify((function(){var seen={},out=[];"
            + "document.querySelectorAll('a[href*=lightning]').forEach(function(a){"
            + "var h=a.href,k=h.indexOf('/lightning/r/');if(k<0)return;"
            + "var p=h.substring(k+13).split('/');"
            + "var id=(p.length>2&&p[2].indexOf('view')==0)?p[1]:p[0];"
            + "var name=(a.textContent||'').trim();"
            + "if(name&&!seen[id]&&(id.indexOf('00Q')==0||id.indexOf('003')==0)){seen[id]=1;out.push({id:id,name:name,url:h});}"
            + "});return out;})())"
        guard let raw = run("""
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            return execute active tab of front window javascript "\(js)"
        end tell
        """), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CallList.Record].self, from: data)
    }
}
