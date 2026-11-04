import SwiftUI

/// "This hour: 12 of 50 · 23:14 left", with a countdown to the top of the hour.
/// Contacts = dials, texts and LinkedIn notes. The goal is 50 every hour.
/// Below: today's total and how many people are due on each active campaign.
struct DailyGoalCard: View {
    @ObservedObject var touchpoints: Touchpoints
    let activeCampaigns: [Campaign]
    @State private var due: [UUID: (people: Int, touches: Int)] = [:]

    static let perHour = 50

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let hour = Calendar.current.dateInterval(of: .hour, for: now)
            let done = touchpoints.contacts(since: hour?.start ?? now)
            let left = max(Int((hour?.end ?? now).timeIntervalSince(now)), 0)
            let hit = done >= Self.perHour
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("This hour: \(done) of \(Self.perHour)").font(.callout.weight(.semibold))
                    Spacer()
                    Text(String(format: "%d:%02d left", left / 60, left % 60))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(hit ? Color.green : left < 600 ? Color.orange : Color.primary)
                }
                ProgressView(value: Double(min(done, Self.perHour)), total: Double(Self.perHour))
                    .tint(hit ? .green : .accentColor)
                Text(hit ? "Goal hit for this hour" : "\(Self.perHour - done) to go")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hit ? Color.green : Color.secondary)
                Text(([ "Today: \(touchpoints.totalAll(in: .today)) contacts" ]
                      + activeCampaigns.compactMap { c in due[c.id].map { "\(c.name): \($0.people) due" } })
                    .joined(separator: " · "))
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
                if step.linkedInConnect, !DialHistory.linkedInMessageToday(r.id) { left += 1 }
                if left > 0 { people += 1; touches += left }
            }
            result[c.id] = (people: people, touches: touches)
        }
        due = result
    }
}
