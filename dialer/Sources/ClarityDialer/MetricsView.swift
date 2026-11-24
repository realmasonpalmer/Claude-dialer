import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct MetricsView: View {
    @Environment(Store.self) private var store
    @State private var period: Period = .today
    @State private var breakdown: Breakdown = .day

    private var attempts: [Attempt] { store.attempts.filter { $0.isLogged && period.contains($0.dialedAt) } }

    var body: some View {
        let s = Metrics.summary(attempts)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    Spacer()
                    Button("Export CSV") { export() }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Tile("Dials", "\(s.dials)", "\(s.uniqueLeads) people")
                    Tile("Pickups", "\(s.connects)", "\(s.connectRate.percent) of dials · lead answered")
                    Tile("Conversations", "\(s.conversations)", "30s+ · \(s.conversationRate.percent)")
                    Tile("Meetings", "\(s.meetings)", "\(s.meetingRate.percent) of pickups")
                    Tile("Talk time", s.talkSeconds.duration, "avg \(s.avgTalkSeconds.duration)")
                    Tile("Dials / hour", String(format: "%.0f", s.dialsPerHour), "\(s.activeSeconds.duration) dialing")
                    Tile("Voicemails", "\(s.voicemails)", "\(s.textsSent) texts sent")
                    Tile("Bad numbers", "\(s.badNumbers)", "\(s.notInterested) not interested")
                }

                Card { Funnel(s: s) }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Break down by", selection: $breakdown) {
                            ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 300)
                        BreakdownTable(rows: Metrics.rows(attempts, by: breakdown))
                    }
                }
            }
            .padding(20)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clarity-dialer-attempts.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Metrics.csv(store.attempts.filter(\.isLogged)).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct Tile: View {
    let title: String, value: String, sub: String
    init(_ title: String, _ value: String, _ sub: String) { self.title = title; self.value = value; self.sub = sub }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text(sub).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Funnel: View {
    let s: Summary
    var body: some View {
        let steps: [(String, Int)] = [("Dials", s.dials), ("Pickups", s.connects), ("Conversations", s.conversations), ("Meetings", s.meetings)]
        VStack(alignment: .leading, spacing: 8) {
            Text("FUNNEL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(steps, id: \.0) { name, n in
                HStack(spacing: 10) {
                    Text(name).frame(width: 110, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 4).fill(Look.accent.opacity(0.85))
                            .frame(width: max(2, g.size.width * CGFloat(n) / CGFloat(max(1, s.dials))))
                    }
                    .frame(height: 16)
                    Text("\(n)").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
        }
    }
}

private struct BreakdownTable: View {
    let rows: [Metrics.Row]
    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(["Dials", "Pickup %", "Convos", "Meetings", "Mtg %", "Talk"], id: \.self) { Text($0) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { r in
                GridRow {
                    Text(r.label).lineLimit(1)
                    Text("\(r.summary.dials)")
                    Text(r.summary.connectRate.percent)
                    Text("\(r.summary.conversations)")
                    Text("\(r.summary.meetings)")
                    Text(r.summary.meetingRate.percent)
                    Text(r.summary.talkSeconds.duration)
                }
                .monospacedDigit()
            }
            if rows.isEmpty { Text("No calls in this period.").foregroundStyle(.secondary) }
        }
    }
}
