import SwiftUI

/// "Today: 32 of 50 contacts · On track", plus how many people are due today on each active
/// campaign. Contacts = dials, texts and LinkedIn notes. The goal is 50 a day, or more if the
/// active campaigns need more to stay on plan.
struct DailyGoalCard: View {
    @ObservedObject var touchpoints: Touchpoints
    let activeCampaigns: [Campaign]
    @State private var due: [UUID: (people: Int, touches: Int)] = [:]

    static let minimum = 50
    /// The workday the pace is measured against (8am to 5pm).
    static let startHour = 8, endHour = 17

    var body: some View {
        let done = touchpoints.totalAll(in: .today)
        let needed = due.values.reduce(0) { $0 + $1.touches }
        let target = max(Self.minimum, done + needed)
        let expected = expectedByNow(target)
        let onTrack = done >= expected
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today: \(done) of \(target) contacts").font(.callout.weight(.semibold))
                Spacer()
                Text(onTrack ? "On track" : "Behind by \(expected - done)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(onTrack ? Color.green : Color.orange)
            }
            ProgressView(value: Double(min(done, target)), total: Double(max(target, 1)))
            if !due.isEmpty {
                Text(activeCampaigns.compactMap { c in due[c.id].map { "\(c.name): \($0.people) due" } }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .task(id: activeCampaigns.map(\.id)) {
            // Recount now and every 10 minutes.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Where you should be by now, spread evenly over the workday.
    private func expectedByNow(_ target: Int) -> Int {
        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(bySettingHour: Self.startHour, minute: 0, second: 0, of: now),
              let end = cal.date(bySettingHour: Self.endHour, minute: 0, second: 0, of: now) else { return 0 }
        let fraction = min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        return Int(Double(target) * fraction)
    }

    /// For each active campaign: people still due today, and the contacts their plan step still needs.
    private func refresh() async {
        guard Salesforce.isConnected else { return }
        var result: [UUID: (people: Int, touches: Int)] = [:]
        for c in activeCampaigns where !c.listViewID.isEmpty {
            guard let rows = try? await Salesforce.fullList(object: c.listObject, key: c.listViewID) else { continue }
            var people = 0, touches = 0
            for r in rows where !RemovedList.contains(r.id) && !DialHistory.isMaxed(r.id) && Cadence.isDue(r.id) {
                guard let step = Cadence.step(for: r.id) else { continue }
                let p = DialHistory.person(r.id)
                let dialsToday = p.dials.filter { Calendar.current.isDateInToday($0) }.count
                var left = max(2 - dialsToday, 0)
                if step.textToday, !DialHistory.textedToday(r.id) { left += 1 }
                if step.linkedInConnect, !DialHistory.linkedInToday(r.id) { left += 1 }
                if left > 0 { people += 1; touches += left }
            }
            result[c.id] = (people: people, touches: touches)
        }
        due = result
    }
}
