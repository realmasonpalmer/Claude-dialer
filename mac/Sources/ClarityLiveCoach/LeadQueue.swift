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
    /// Called today (shared with the Chrome list, see `CalledToday`). Kept here so views update.
    @Published private(set) var calledToday: Set<String> = []

    var isActive: Bool { Salesforce.isConnected && selected != nil && !rows.isEmpty }
    var current: Salesforce.Row? { rows.indices.contains(index) ? rows[index] : nil }
    var leftToCall: Int { rows.filter { CalledToday.isCallable($0.id) }.count }
    /// On the plan but not due today: they come back on a later call day.
    var comingBackLater: Int { rows.filter { Cadence.comesBackLater($0.id) }.count }
    /// Due today, but in a time zone the rep isn't calling right now.
    var heldByTimeZone: Int { TimeZoneFilter.heldBack(rows.map(\.id)) }
    /// Called today on this list.
    var calledHere: Int { rows.filter { calledToday.contains($0.id) }.count }
    var nextRow: Salesforce.Row? { nextIndex(after: index).map { rows[$0] } }
    var canGoBack: Bool { index > 0 }

    init() {
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
            let saved = UserDefaults.standard.string(forKey: PrefKey.sfListView)
            if let view = views.first(where: { $0.id == saved }) { await open(view) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ view: Salesforce.ListView) async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await Salesforce.rows(of: view)
            // Follow-ups due today first (day 2, 5, 8, 16), then new people, each in list order.
            let followUps = loaded.filter { Cadence.isFollowUp($0.id) && CalledToday.isCallable($0.id) }
            let followUpIDs = Set(followUps.map(\.id))
            rows = followUps + loaded.filter { !followUpIDs.contains($0.id) }
            selected = view
            error = nil
            UserDefaults.standard.set(view.id, forKey: PrefKey.sfListView)
            // Start at the first one due today. Nobody due: show nobody (not someone the plan skips).
            index = rows.firstIndex { CalledToday.isCallable($0.id) } ?? rows.count
            await loadDetails()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stops using the Salesforce list; the app goes back to the list open in Chrome.
    func close() {
        selected = nil
        rows = []
        details = nil
        index = 0
        UserDefaults.standard.removeObject(forKey: PrefKey.sfListView)
    }

    /// Picks up changes made in Salesforce (new leads, edits), keeping the current lead.
    /// - Parameter keepCurrent: false = go to the first person due (used when the list ran out).
    func reload(keepCurrent: Bool = true) async {
        guard let selected else { return }
        let currentID = keepCurrent ? current?.id : nil
        await open(selected)
        if let currentID, let i = rows.firstIndex(where: { $0.id == currentID }) {
            index = i
            await loadDetails()
        }
    }

    /// The time zone filter changed. Stay on the current person if they still fit;
    /// if not, go to the first person due in the new time zone.
    func timeZoneChanged() async {
        guard selected != nil else { return }
        if let current, TimeZoneFilter.allows(current.id) {
            objectWillChange.send() // the counts changed
            return
        }
        index = rows.firstIndex { CalledToday.isCallable($0.id) } ?? rows.count
        details = nil
        await loadDetails()
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
            if CalledToday.isCallable(rows[j].id) { return j }
            j += 1
        }
        return nil
    }

    // MARK: Called today

    func markCurrentCalled() {
        resetIfNewDay()
        guard let id = current?.id else { return }
        CalledToday.add(id)
        calledToday = CalledToday.ids
    }

    func clearCalledToday() {
        CalledToday.clear()
        calledToday = CalledToday.ids
    }

    private func resetIfNewDay() {
        CalledToday.resetIfNewDay()
        calledToday = CalledToday.ids
    }
}
