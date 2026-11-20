import SwiftUI
import CoachCore

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
        /// The person (Lead or Contact Id), when it's a call.
        var lead: String? = nil
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

    func log(_ kind: Kind, at: Date = Date(), campaign: String? = nil, lead: String? = nil) {
        events.append(Event(kind: kind, at: at, campaign: campaign ?? currentCampaign, lead: lead))
        // Keep about two years, so the file stays small.
        let cutoff = Calendar.current.date(byAdding: .day, value: -730, to: Date()) ?? .distantPast
        if events.first.map({ $0.at < cutoff }) == true { events.removeAll { $0.at < cutoff } }
        save()
    }

    private func save() {
        do {
            try JSONEncoder().encode(events).write(to: Self.file, options: .atomic)
        } catch {
            ActivityLog.problem("My numbers: couldn't save touchpoints.json (\(error.localizedDescription))")
        }
    }

    /// Wipes today's counts (all campaigns). Older days stay.
    func resetToday() {
        let start = Self.start(of: .today)
        events.removeAll { $0.at >= start }
        save()
    }

    /// Every contact today, across all campaigns (dials + texts + LinkedIn), for the daily goal.
    func totalAll(in period: Period) -> Int {
        let start = Self.start(of: period)
        let contacts: Set<Kind> = [.dial, .text, .linkedin, .linkedinMessage]
        return events.filter { contacts.contains($0.kind) && $0.at >= start }.count
    }

    /// Every contact since a time, across all campaigns, for the hourly goal.
    /// Dials only, between two times (the call block counts dials).
    func dials(from start: Date, to end: Date) -> Int {
        events.filter { $0.kind == .dial && $0.at >= start && $0.at < end }.count
    }

    func contacts(from start: Date, to end: Date) -> Int {
        events.filter { Self.contactKinds.contains($0.kind) && $0.at >= start && $0.at < end }.count
    }

    func contacts(since start: Date) -> Int {
        let contacts: Set<Kind> = [.dial, .text, .linkedin, .linkedinMessage]
        return events.filter { contacts.contains($0.kind) && $0.at >= start }.count
    }

    private static let contactKinds: Set<Kind> = [.dial, .text, .linkedin, .linkedinMessage]

    /// Contacts in each clock hour today, from the first busy hour (or now) to this hour. At most 12.
    func contactsByHourToday() -> [Int] {
        let cal = Calendar.current
        let now = Date()
        let today = events.filter { Self.contactKinds.contains($0.kind) && cal.isDateInToday($0.at) }
        let thisHour = cal.component(.hour, from: now)
        let firstHour = today.map { cal.component(.hour, from: $0.at) }.min() ?? thisHour
        var counts = Array(repeating: 0, count: thisHour - firstHour + 1)
        for e in today { counts[cal.component(.hour, from: e.at) - firstHour] += 1 }
        return Array(counts.suffix(12))
    }

    /// The last day before today with any contacts: its name ("yesterday", "Friday") and its total.
    func lastDay() -> (name: String, total: Int)? {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        guard let last = events.last(where: { Self.contactKinds.contains($0.kind) && $0.at < startToday }) else { return nil }
        let day = cal.startOfDay(for: last.at)
        let total = events.filter { Self.contactKinds.contains($0.kind) && $0.at >= day && $0.at < startToday
                                    && cal.isDate($0.at, inSameDayAs: day) }.count
        let name = cal.isDateInYesterday(day) ? "yesterday" : day.formatted(.dateTime.weekday(.wide))
        return (name, total)
    }

    /// Meetings booked this week, all campaigns.
    func meetingsThisWeek() -> Int {
        let start = Self.start(of: .week)
        return events.filter { $0.kind == .meeting && $0.at >= start }.count
    }

    func count(_ kind: Kind, in period: Period) -> Int {
        let start = Self.start(of: period)
        return events.filter { $0.kind == kind && $0.at >= start && (showCampaign == nil || $0.campaign == showCampaign) }.count
    }

    /// Every way you reached out: dials + texts + LinkedIn notes + LinkedIn messages.
    func total(in period: Period) -> Int {
        count(.dial, in: period) + count(.text, in: period) + count(.linkedin, in: period) + count(.linkedinMessage, in: period)
    }

    /// Human answer, prospect reach and conversation rates, from the call records (per dial).
    func pickupStats(in period: Period) -> PickupStats {
        PickupStats(CallAttemptStore.shared.finished(since: Self.start(of: period), campaign: showCampaign))
    }

    static func start(of period: Period) -> Date {
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
    /// "Today: 3 late · 12 due · 30 new", shown as "251 to call".
    var toCall: String? = nil
    @AppStorage(PrefKey.touchpointsPeriod) private var periodRaw = Touchpoints.Period.today.rawValue
    @AppStorage(PrefKey.touchpointsOpen) private var open = false
    @AppStorage("activityCardOpen") private var cardOpen = true
    @State private var confirmReset = false

    private var period: Touchpoints.Period { Touchpoints.Period(rawValue: periodRaw) ?? .today }

    var body: some View {
        let t = touchpoints
        let dials = t.count(.dial, in: period)
        let pickups = t.count(.pickup, in: period)
        let ps = t.pickupStats(in: period)
        let meetings = t.count(.meeting, in: period)
        VStack(alignment: .leading, spacing: 10) {
            // Always: the title, the date filter and the four numbers that matter.
            HStack(spacing: 8) {
                Button { cardOpen.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cardOpen ? "chevron.down" : "chevron.right").font(CardStyle.chevron)
                            .foregroundStyle(Brand.subtext)
                        Image(systemName: "chart.bar").font(CardStyle.icon).foregroundStyle(Brand.blue)
                        Text("My Activity").font(CardStyle.title).foregroundStyle(Brand.text)
                        if !cardOpen {
                            Text("· \(dials) dials · \(meetings) meetings").font(.caption).foregroundStyle(Brand.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let toCall {
                    Text("· " + CallQueue.short(toCall)).font(.caption).foregroundStyle(Brand.muted).help(toCall)
                }
                Spacer(minLength: 0)
                Picker("", selection: $periodRaw) {
                    ForEach(Touchpoints.Period.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if cardOpen {
            HStack(spacing: 8) {
                tile("Dials", dials)
                tile("Human answers", pickups)
                tile("Conversations", t.count(.conversation, in: period))
                tile("Meetings", meetings, highlight: meetings > 0)
            }
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text(open ? "Fewer details" : "More details").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Brand.subtext)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
            HStack {
                Text("Call list").font(.caption).foregroundStyle(Brand.muted)
                Picker("", selection: $touchpoints.showCampaign) {
                    Text("All scripts").tag(String?.none)
                    ForEach(touchpoints.campaignNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { stat("Voicemails", t.count(.voicemail, in: period)); stat("Texts", t.count(.text, in: period)) }
                GridRow { stat("LinkedIn notes", t.count(.linkedin, in: period)); stat("LinkedIn messages", t.count(.linkedinMessage, in: period)) }
                GridRow { stat("All touches", t.total(in: period)); Text("dials, texts and notes").font(.caption).foregroundStyle(Brand.muted) }
            }
            // Rates come from the per-call records. Only shown once there are records to divide by,
            // so they never read as 0% next to hundreds of dials.
            if ps.placedDials > 0 {
                Text("Rates per dial (\(ps.placedDials) dials with a full record)").font(.caption.weight(.semibold)).foregroundStyle(Brand.subtext)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { stat("Human answer", rate(ps.humanAnswerRate)); stat("Conversation", rate(ps.conversationRate)) }
                    GridRow { stat("Prospect reach", rate(ps.prospectReachRate)); Text("\(ps.leadsReached) of \(ps.leadsAttempted) people").font(.caption).foregroundStyle(Brand.muted) }
                }
                .help("Human answer: a person answered (gatekeepers count). Prospect reach: people you reached ÷ people you dialed. Conversation: real talks with the prospect ÷ dials.")
            } else {
                Text("Rates per dial show once calls placed with this version add up.").font(.caption).foregroundStyle(Brand.muted)
            }
            if meetings > 0 {
                Text("\(dials / max(meetings, 1)) dials per meeting").font(.caption).foregroundStyle(Brand.muted)
            }
            Button("Set today back to zero") { confirmReset = true }
                .buttonStyle(.brandLink).font(.caption)
                .confirmationDialog("Set today's numbers back to zero?", isPresented: $confirmReset) {
                    Button("Set to zero", role: .destructive) { touchpoints.resetToday() }
                    Button("Cancel", role: .cancel) {}
                }
            }
            }
        }
        .padding(CardStyle.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: CardStyle.radius)
    }

    /// One of the four main numbers: big value, small label.
    private func tile(_ label: String, _ value: Int, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(highlight ? Color.green : Brand.text)
            Text(label).font(.caption).foregroundStyle(Brand.subtext).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.navy.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ label: String, _ value: Int) -> some View { stat(label, "\(value)") }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func rate(_ r: Double?) -> String { r.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    private func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "–" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }
}
