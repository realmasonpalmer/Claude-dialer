import Foundation

/// The rep's call list, straight from a Salesforce list view: who's up, who's next,
/// and who's been called today. Replaces reading the Salesforce page in Chrome.
@MainActor
final class LeadQueue: ObservableObject {
    @Published private(set) var views: [Salesforce.ListView] = []
    @Published private(set) var selected: Salesforce.ListView?
    @Published private(set) var rows: [Salesforce.Row] = []
    @Published private(set) var index = 0
    @Published private(set) var details: Salesforce.Details?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var calledToday: Set<String> = []
    private var calledDay = ""

    var isActive: Bool { Salesforce.isConnected && selected != nil && !rows.isEmpty }
    var current: Salesforce.Row? { rows.indices.contains(index) ? rows[index] : nil }
    var leftToCall: Int { rows.filter { !calledToday.contains($0.id) }.count }
    var nextRow: Salesforce.Row? { nextIndex(after: index).map { rows[$0] } }
    var canGoBack: Bool { index > 0 }

    init() {
        let d = UserDefaults.standard
        calledDay = d.string(forKey: "sfCalledDay") ?? ""
        calledToday = Set(d.stringArray(forKey: "sfCalledToday") ?? [])
        resetIfNewDay()
    }

    // MARK: Loading

    /// Loads the list views, then reopens the last list used.
    func start() async {
        guard Salesforce.isConnected, views.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            views = try await Salesforce.listViews()
            error = nil
            let saved = UserDefaults.standard.string(forKey: "sfListView")
            if let view = views.first(where: { $0.id == saved }) { await open(view) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ view: Salesforce.ListView) async {
        loading = true
        defer { loading = false }
        do {
            rows = try await Salesforce.rows(of: view)
            selected = view
            error = nil
            UserDefaults.standard.set(view.id, forKey: "sfListView")
            // Start at the first one not called today.
            index = rows.firstIndex { !calledToday.contains($0.id) } ?? 0
            await loadDetails()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Picks up changes made in Salesforce (new leads, edits), keeping the current lead.
    func reload() async {
        guard let selected else { return }
        let currentID = current?.id
        await open(selected)
        if let currentID, let i = rows.firstIndex(where: { $0.id == currentID }) {
            index = i
            await loadDetails()
        }
    }

    private func loadDetails() async {
        guard let row = current, let object = selected?.object else { details = nil; return }
        do {
            let loaded = try await Salesforce.details(id: row.id, object: object)
            if current?.id == row.id { details = loaded } // ignore if the rep already moved on
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Moving

    /// The next lead not called today. Returns false at the end of the list.
    @discardableResult
    func next() async -> Bool {
        resetIfNewDay()
        guard let i = nextIndex(after: index) else { return false }
        index = i
        details = nil
        await loadDetails()
        return true
    }

    func back() async {
        guard index > 0 else { return }
        index -= 1
        details = nil
        await loadDetails()
    }

    private func nextIndex(after i: Int) -> Int? {
        var j = i + 1
        while j < rows.count {
            if !calledToday.contains(rows[j].id) { return j }
            j += 1
        }
        return nil
    }

    // MARK: Called today

    func markCurrentCalled() {
        resetIfNewDay()
        guard let id = current?.id else { return }
        calledToday.insert(id)
        save()
    }

    func clearCalledToday() {
        calledToday = []
        save()
    }

    private func resetIfNewDay() {
        let today = Date().formatted(.iso8601.year().month().day())
        if calledDay != today {
            calledDay = today
            calledToday = []
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(calledDay, forKey: "sfCalledDay")
        UserDefaults.standard.set(Array(calledToday), forKey: "sfCalledToday")
    }
}
