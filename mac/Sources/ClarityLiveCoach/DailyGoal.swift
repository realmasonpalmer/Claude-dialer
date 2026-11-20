import SwiftUI

/// "Call Block: 12 / 50 Dials": dials in the 50 minute block running now. One ring per block today.
/// Contacts = dials, texts and LinkedIn notes. The goal is 50 every hour.
/// Below: today's total and how many people are due on each active campaign.
struct DailyGoalCard: View {
    @ObservedObject var touchpoints: Touchpoints
    @ObservedObject var coach: CoachModel
    let activeCampaigns: [Campaign]
    @State private var due: [UUID: (people: Int, touches: Int)] = [:]
    /// Folded: the hour's count, time left and the bar. Open: today's total and what's due.
    @AppStorage(PrefKey.goalCardOpen) private var open = false

    static let perHour = 50

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let blocks = BlockLog.today()
            // The count is for the block running now (or the last one today). No block yet: 0.
            let current = blocks.last
            let done = current.map { touchpoints.dials(from: $0, to: BlockLog.end(of: $0, in: blocks, now: now)) } ?? 0
            let hit = done >= Self.perHour
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { open.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                            HStack(spacing: 0) {
                                Text("This block: ")
                                Text("\(done)")
                                    .contentTransition(.numericText(value: Double(done)))
                                    .animation(.snappy, value: done)
                                Text(" of \(Self.perHour)")
                            }
                            .font(.callout.weight(.semibold).monospacedDigit())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    blockControl(now: now)
                }
                ProgressView(value: Double(min(done, Self.perHour)), total: Double(Self.perHour))
                    .tint(hit ? .green : Brand.blue)
                    .animation(.easeOut(duration: 0.4), value: done)
                // One ring per 50 min block started today, filling with that block's contacts.
                HStack(spacing: 5) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, start in
                        let count = touchpoints.dials(from: start, to: BlockLog.end(of: start, in: blocks, now: now))
                        HourRing(progress: Double(count) / Double(Self.perHour))
                    }
                    Spacer(minLength: 8)
                    if let line = beatLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if open {
                Text(hit ? "Goal hit: 50 dials in this block" : "\(Self.perHour - done) dials to go · goal: 50 dials in 50 minutes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hit ? Color.green : Color.secondary)
                Text(([ "Today: \(touchpoints.totalAll(in: .today)) contacts · \(blocks.count) block\(blocks.count == 1 ? "" : "s")" ]
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
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Start a 50 min block, or its time left with Stop, or the break with Skip.
    @ViewBuilder private func blockControl(now: Date) -> some View {
        if let until = coach.breakUntil {
            let left = max(0, Int(until.timeIntervalSince(now)))
            Text(String(format: "Break %d:%02d", left / 60, left % 60)).font(.caption.monospacedDigit())
            Button("Skip break") { coach.endBreak() }.buttonStyle(.brandLink).font(.caption)
        } else if let start = coach.blockStartedAt {
            let left = max(0, Int(CoachModel.blockLength - now.timeIntervalSince(start)))
            Text(String(format: "%d:%02d left", left / 60, left % 60)).font(.callout.weight(.semibold).monospacedDigit())
            Button("End Block") { coach.stopBlock() }.buttonStyle(.brandLink).font(.caption)
        } else {
            Button("Start Block") { coach.startBlock() }
                .buttonStyle(BrandPrimaryButton(color: Brand.blue)).controlSize(.small)
                .help("Goal: 50 dials in 50 minutes, then a 10 minute break. Each block gets its own ring.")
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

/// The 50 minute blocks started today, saved so the rings survive a restart.
enum BlockLog {
    private static let key = "blockStarts"

    static func today() -> [Date] {
        let all = (UserDefaults.standard.array(forKey: key) as? [Double]) ?? []
        return all.map { Date(timeIntervalSince1970: $0) }.filter { Calendar.current.isDateInToday($0) }
    }

    static func add(_ start: Date) {
        let kept = today().map(\.timeIntervalSince1970) // drops earlier days
        UserDefaults.standard.set(kept + [start.timeIntervalSince1970], forKey: key)
    }

    /// A block counts until 50 minutes pass, the next block starts, or now.
    static func end(of start: Date, in blocks: [Date], now: Date) -> Date {
        var end = min(start.addingTimeInterval(CoachModel.blockLength), now)
        if let next = blocks.first(where: { $0 > start }) { end = min(end, next) }
        return end
    }
}
