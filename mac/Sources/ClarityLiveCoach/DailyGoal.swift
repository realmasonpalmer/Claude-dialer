import SwiftUI

/// "This hour: 12 of 50 · 23:14 left", with a countdown to the top of the hour.
/// Contacts = dials, texts and LinkedIn notes. The goal is 50 every hour.
/// Below: today's total and how many people are due on each active campaign.
struct DailyGoalCard: View {
    @ObservedObject var touchpoints: Touchpoints
    let activeCampaigns: [Campaign]
    @State private var due: [UUID: (people: Int, touches: Int)] = [:]
    /// Folded: the hour's count, time left and the bar. Open: today's total and what's due.
    @AppStorage(PrefKey.goalCardOpen) private var open = false

    static let perHour = 50

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let hour = Calendar.current.dateInterval(of: .hour, for: now)
            let done = touchpoints.contacts(since: hour?.start ?? now)
            let left = max(Int((hour?.end ?? now).timeIntervalSince(now)), 0)
            let hit = done >= Self.perHour
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                        // The count rolls up like a clock digit each time it changes.
                        HStack(spacing: 0) {
                            Text("This hour: ")
                            Text("\(done)")
                                .contentTransition(.numericText(value: Double(done)))
                                .animation(.snappy, value: done)
                            Text(" of \(Self.perHour)")
                        }
                        .font(.callout.weight(.semibold).monospacedDigit())
                        Spacer()
                        Text(String(format: "%d:%02d left", left / 60, left % 60))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(hit ? Color.green : left < 600 ? Color.orange : Color.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                let hours = touchpoints.contactsByHourToday()
                let closed = hours.filter { $0 >= Self.perHour }.count
                ProgressView(value: Double(min(done, Self.perHour)), total: Double(Self.perHour))
                    .tint(hit ? .green : Brand.blue)
                    .animation(.easeOut(duration: 0.4), value: done)
                    // One soft pulse when the hour's goal is hit.
                    .keyframeAnimator(initialValue: 1.0, trigger: closed) { content, scale in
                        content.scaleEffect(x: 1, y: scale)
                    } keyframes: { _ in
                        SpringKeyframe(2.2, duration: 0.18)
                        SpringKeyframe(1.0, duration: 0.5)
                    }
                // One ring per hour today, closing at the goal. And how today compares with last time.
                HStack(spacing: 5) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { _, count in
                        HourRing(progress: Double(count) / Double(Self.perHour))
                    }
                    Spacer(minLength: 8)
                    if let line = beatLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if open {
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
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
        .task(id: activeCampaigns.map(\.id)) {
            // Recount now and every 10 minutes.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// "4 more to beat yesterday", then "Ahead of yesterday" once passed.
    private var beatLine: String? {
        guard let last = touchpoints.lastDay(), last.total > 0 else { return nil }
        let today = touchpoints.totalAll(in: .today)
        return today > last.total ? "Ahead of \(last.name)" : "\(last.total - today + 1) more to beat \(last.name)"
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

/// A small ring that fills as the hour's contacts add up, and turns green when it closes.
struct HourRing: View {
    let progress: Double

    var body: some View {
        let done = progress >= 1
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(done ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
        .frame(width: 10, height: 10)
        .help(done ? "Goal hit this hour" : "\(Int(progress * 100))% of the hour's goal")
    }
}
