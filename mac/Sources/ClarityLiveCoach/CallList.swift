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
    private var lastIndex: Int
    private var lastCapture = Date.distantPast

    init() {
        lastIndex = UserDefaults.standard.integer(forKey: "callListIndex")
        if let data = UserDefaults.standard.data(forKey: "callList"),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
    }

    /// While a Salesforce list view is open, learn its order (checked every few seconds).
    func captureIfListView() {
        guard Date().timeIntervalSince(lastCapture) > 4,
              let url = ChromeTab.url(), url.contains("lightning.force.com"),
              url.contains("/list") || url.contains("filterName=") else { return }
        lastCapture = Date()
        guard let found = ChromeTab.listRecords(), found.count >= 2 else { return }
        if found != records {
            records = found
            lastIndex = -1
            message = "Learned your list: \(found.count) records."
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
        guard ChromeTab.open(record.url) else {
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
