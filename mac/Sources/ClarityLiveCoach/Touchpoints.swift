import SwiftUI

/// Counts every touchpoint on this Mac (no Salesforce needed): dials, pickups, conversations,
/// voicemails, texts, LinkedIn notes and meetings booked. Filled in automatically by the coach.
@MainActor
final class Touchpoints: ObservableObject {
    enum Kind: String, Codable, CaseIterable {
        case dial, pickup, conversation, voicemail, text, linkedin, linkedinMessage, meeting
    }
    struct Event: Codable {
        let kind: Kind
        let at: Date
        /// The campaign it happened in (older events have none).
        var campaign: String? = nil
    }

    /// The campaign being worked right now; every touchpoint is tagged with it.
    var currentCampaign: String?
    /// Which campaign the card shows: nil = all campaigns.
    @Published var showCampaign: String?

    /// Campaigns that have touchpoints, for the card's picker.
    var campaignNames: [String] { Array(Set(events.compactMap(\.campaign))).sorted() }

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", week = "This week", month = "This month", all = "All time"
        var id: String { rawValue }
    }

    @Published private(set) var events: [Event] = []

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClarityLiveCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("touchpoints.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved
        }
    }

    func log(_ kind: Kind) {
        events.append(Event(kind: kind, at: Date(), campaign: currentCampaign))
        // Keep about two years, so the file stays small.
        let cutoff = Calendar.current.date(byAdding: .day, value: -730, to: Date()) ?? .distantPast
        if events.first.map({ $0.at < cutoff }) == true { events.removeAll { $0.at < cutoff } }
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: Self.file, options: .atomic) }
    }

    func count(_ kind: Kind, in period: Period) -> Int {
        let start = Self.start(of: period)
        return events.filter { $0.kind == kind && $0.at >= start && (showCampaign == nil || $0.campaign == showCampaign) }.count
    }

    /// Every way you reached out: dials + texts + LinkedIn notes + LinkedIn messages.
    func total(in period: Period) -> Int {
        count(.dial, in: period) + count(.text, in: period) + count(.linkedin, in: period) + count(.linkedinMessage, in: period)
    }

    private static func start(of period: Period) -> Date {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        case .month: return cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        case .all: return .distantPast
        }
    }
}

/// The Touchpoints card: pick a time period, see the numbers that matter.
struct TouchpointsCard: View {
    @ObservedObject var touchpoints: Touchpoints
    @AppStorage("touchpointsPeriod") private var periodRaw = Touchpoints.Period.today.rawValue
    @AppStorage("touchpointsOpen") private var open = false

    private var period: Touchpoints.Period { Touchpoints.Period(rawValue: periodRaw) ?? .today }

    var body: some View {
        let t = touchpoints
        let dials = t.count(.dial, in: period)
        let pickups = t.count(.pickup, in: period)
        let meetings = t.count(.meeting, in: period)
        VStack(alignment: .leading, spacing: 8) {
            // Folded: one line. Click to see everything.
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text(open ? "Touchpoints" : "\(t.total(in: period)) touchpoints \(period.rawValue.lowercased()) · \(dials) calls · \(meetings) meetings")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
            HStack {
                // Compare campaigns: each list + script on its own.
                Picker("", selection: $touchpoints.showCampaign) {
                    Text("All campaigns").tag(String?.none)
                    ForEach(touchpoints.campaignNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Picker("", selection: $periodRaw) {
                    ForEach(Touchpoints.Period.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(t.total(in: period))").font(.title.weight(.semibold)).monospacedDigit()
                Text("total touchpoints").font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { stat("Calls", dials); stat("Picked up", pickups) }
                GridRow { stat("Conversations", t.count(.conversation, in: period)); stat("Voicemails", t.count(.voicemail, in: period)) }
                GridRow { stat("Texts", t.count(.text, in: period)); stat("LinkedIn notes", t.count(.linkedin, in: period)) }
                GridRow { stat("LinkedIn messages", t.count(.linkedinMessage, in: period)); stat("Meetings booked", meetings) }
                GridRow { stat("Pickup rate", percent(pickups, of: dials)); Color.clear.frame(height: 1) }
            }
            if meetings > 0 {
                Text("\(dials / max(meetings, 1)) calls per meeting").font(.caption).foregroundStyle(.secondary)
            }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: Int) -> some View { stat(label, "\(value)") }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "–" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }
}
