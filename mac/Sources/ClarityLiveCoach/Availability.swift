import EventKit
import SwiftUI

/// Reads free time from the calendar the rep books meetings on (usually the boss's).
/// Main way: the calendar's link or iCal address, read directly (CalendarFeed).
/// Backup way: a calendar synced to macOS Calendar (EventKit).
/// Only busy/free times are used; event titles and details are never sent anywhere.
@MainActor
final class Availability: ObservableObject {
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [EKCalendar] = []
    @Published var selectedIDs: Set<String> { didSet { save() } }
    @Published var startHour: Int { didSet { save() } }
    @Published var endHour: Int { didSet { save() } }
    @Published var meetingMinutes: Int { didSet { save() } }

    /// The booking calendar's address, e.g. oliver@company.com or an embed / iCal link.
    @Published private(set) var feedInput: String?
    @Published private(set) var feedStatus: String?
    @Published private(set) var loadingFeed = false
    private var feed: CalendarFeed.Result?
    private var feedLoadedAt: Date?

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private var cached: (at: Date, text: String?)?

    var usesFeed: Bool { feedInput != nil }

    var hasAccess: Bool { status == .fullAccess }

    init() {
        selectedIDs = Set(UserDefaults.standard.stringArray(forKey: "bookingCalendars") ?? [])
        startHour = UserDefaults.standard.object(forKey: "bookingStartHour") as? Int ?? 9
        endHour = UserDefaults.standard.object(forKey: "bookingEndHour") as? Int ?? 17
        meetingMinutes = UserDefaults.standard.object(forKey: "bookingMinutes") as? Int ?? 30
        feedInput = Keychain.read(.calendarFeed)
        loadCalendars()
        if usesFeed { Task { await loadFeed() } }
    }

    // MARK: Calendar by link

    /// Saves the calendar address and checks that it can be read.
    func useFeed(_ input: String) async {
        guard CalendarFeed.feedURL(from: input) != nil else {
            feedStatus = "That doesn't look like a calendar link or email."
            return
        }
        feedInput = input.trimmed
        Keychain.save(input.trimmed, for: .calendarFeed)
        await loadFeed()
    }

    func removeFeed() {
        Keychain.delete(.calendarFeed)
        feedInput = nil
        feed = nil
        feedStatus = nil
        cached = nil
    }

    func loadFeed() async {
        guard let input = feedInput, let url = CalendarFeed.feedURL(from: input) else { return }
        loadingFeed = true
        defer { loadingFeed = false }
        do {
            let result = try await CalendarFeed.load(url)
            feed = result
            feedLoadedAt = Date()
            feedStatus = "Connected. \(result.busy.count) busy blocks in the next 2 weeks."
        } catch {
            feedStatus = error.localizedDescription
        }
        cached = nil
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        status = EKEventStore.authorizationStatus(for: .event)
        loadCalendars()
    }

    func loadCalendars() {
        guard hasAccess else { return }
        calendars = store.calendars(for: .event)
            .filter { $0.type != .birthday }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        // Nothing is picked by default: the rep chooses the calendar they book on (often someone else's).
        if !calendars.isEmpty {
            selectedIDs = selectedIDs.filter { id in calendars.contains { $0.calendarIdentifier == id } }
        }
    }

    // MARK: Open times

    /// Free windows for the next 5 workdays, as plain text for Claude. Cached for 2 minutes.
    func openTimesText() -> String? {
        if let cached, Date().timeIntervalSince(cached.at) < 120 { return cached.text }
        let text = computeOpenTimes()
        cached = (Date(), text)
        return text
    }

    func refresh() {
        cached = nil
        if usesFeed { Task { await loadFeed() } }
        objectWillChange.send()
    }

    /// Busy blocks between two times, from the link (main) or macOS Calendar (backup).
    private func busyBlocks(_ open: Date, _ close: Date) -> [(Date, Date)]? {
        if usesFeed {
            guard let feed else { return nil }
            if let at = feedLoadedAt, Date().timeIntervalSince(at) > 600, !loadingFeed {
                Task { await loadFeed() } // stale: refresh in the background
            }
            return feed.busy.filter { $0.start < close && $0.end > open }.map { ($0.start, $0.end) }
        }
        let chosen = calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
        guard hasAccess, !chosen.isEmpty else { return nil }
        return store.events(matching: store.predicateForEvents(withStart: open, end: close, calendars: chosen))
            .filter { !$0.isAllDay && $0.availability != .free }
            .map { ($0.startDate!, $0.endDate!) }
    }

    private func computeOpenTimes() -> String? {
        guard endHour > startHour else { return nil }
        if usesFeed ? feed == nil : (!hasAccess || selectedIDs.isEmpty) { return nil }
        // Booking hours follow the calendar's own time zone when the link says it.
        var cal = Calendar.current
        let zone = (usesFeed ? feed?.timeZone : nil) ?? TimeZone.current
        cal.timeZone = zone
        let now = Date()
        let meeting = TimeInterval(meetingMinutes * 60)
        // Leave at least an hour before the earliest meeting.
        let earliest = now.addingTimeInterval(3600)

        var lines: [String] = []
        var day = cal.startOfDay(for: now)
        var checked = 0
        while lines.count < 5 && checked < 14 {
            defer { day = cal.date(byAdding: .day, value: 1, to: day)!; checked += 1 }
            guard !cal.isDateInWeekend(day),
                  let open = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
                  let close = cal.date(bySettingHour: endHour, minute: 0, second: 0, of: day),
                  close > earliest else { continue }

            guard let busy = busyBlocks(open, close) else { return nil }

            // Walk the day in half-hour steps and merge free starts into windows.
            var windows: [(Date, Date)] = []
            var slot = max(open, roundUpToHalfHour(earliest, cal))
            while slot.addingTimeInterval(meeting) <= close {
                let end = slot.addingTimeInterval(meeting)
                let free = !busy.contains { $0.0 < end && $0.1 > slot }
                if free {
                    if let last = windows.last, last.1 >= slot { windows[windows.count - 1].1 = end }
                    else { windows.append((slot, end)) }
                }
                slot = slot.addingTimeInterval(1800)
            }
            guard !windows.isEmpty else { continue }
            let dayName = format(day, .dateTime.weekday(.wide).month(.abbreviated).day(), zone)
            let ranges = windows.map { "\(format($0.0, .dateTime.hour().minute(), zone))-\(format($0.1, .dateTime.hour().minute(), zone))" }
                .joined(separator: ", ")
            lines.append("\(dayName): \(ranges)")
        }
        guard !lines.isEmpty else { return nil }
        let zoneName = zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
        return "Times are in \(zoneName) time. Meeting length: \(meetingMinutes) minutes.\n" + lines.joined(separator: "\n")
    }

    private func roundUpToHalfHour(_ date: Date, _ cal: Calendar) -> Date {
        let minute = cal.component(.minute, from: date)
        let add = minute == 0 || minute == 30 ? 0 : (minute < 30 ? 30 - minute : 60 - minute)
        let rounded = cal.date(byAdding: .minute, value: add, to: date)!
        return cal.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    private func format(_ date: Date, _ style: Date.FormatStyle, _ zone: TimeZone) -> String {
        var style = style
        style.timeZone = zone
        return date.formatted(style)
    }

    private func save() {
        defaults.set(Array(selectedIDs), forKey: "bookingCalendars")
        defaults.set(startHour, forKey: "bookingStartHour")
        defaults.set(endHour, forKey: "bookingEndHour")
        defaults.set(meetingMinutes, forKey: "bookingMinutes")
        cached = nil
    }
}

// MARK: - Settings sheet

struct BookingCalendarView: View {
    @ObservedObject var availability: Availability
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var showMacOption = false
    @State private var showOwnerSteps = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Booking calendar").font(.title2.weight(.semibold))
                Text("When you ask for the meeting, the coach offers real open times from the calendar you book on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                linkSection
                if availability.usesFeed || availability.hasAccess { hoursSection }
                if !availability.usesFeed { macSection }

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 370, height: 560)
        .onAppear {
            link = availability.feedInput ?? ""
            availability.loadCalendars()
        }
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar link").font(.headline)
            Text("Paste the calendar's link or the owner's email, like oliver@clarityconsulting.io.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Calendar link or email", text: $link)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(availability.usesFeed ? "Update" : "Connect") {
                    Task { await availability.useFeed(link) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.trimmed.isEmpty || availability.loadingFeed)
                if availability.usesFeed {
                    Button("Remove") {
                        availability.removeFeed()
                        link = ""
                    }
                }
                if availability.loadingFeed { ProgressView().controlSize(.small) }
            }
            if let status = availability.feedStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(status.hasPrefix("Connected") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Steps for the calendar owner", isExpanded: $showOwnerSteps) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Done once, by the calendar's owner (for example Oliver):")
                    Text("1. Open calendar.google.com on a computer.")
                    Text("2. Settings (gear icon) > Settings, then click their calendar on the left.")
                    Text("3. Under Access permissions, check \"Make available to public\" and pick \"See only free/busy (hide details)\".")
                    Text("4. Click OK. Then come back here and click Connect.")
                    Text("Only busy blocks are shared, never meeting names or details. If that option is greyed out, the Google Workspace admin needs to allow it. Another option: they copy \"Secret address in iCal format\" from the same page and send it to you to paste above.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private var hoursSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Booking hours").font(.headline)
            HStack {
                Stepper("From \(hourLabel(availability.startHour))", value: $availability.startHour, in: 6...12)
                Stepper("to \(hourLabel(availability.endHour))", value: $availability.endHour, in: 13...21)
            }
            .font(.callout)
            Picker("Meeting length", selection: $availability.meetingMinutes) {
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("45 min").tag(45)
                Text("60 min").tag(60)
            }
            .pickerStyle(.segmented)

            Text("Next open times").font(.callout.weight(.semibold))
            Text(availability.openTimesText() ?? "No open times yet. Connect a calendar above.")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Backup option: a calendar already synced to the Mac's Calendar app.
    private var macSection: some View {
        DisclosureGroup("Or use a calendar on this Mac", isExpanded: $showMacOption) {
            VStack(alignment: .leading, spacing: 8) {
                if !availability.hasAccess {
                    Button("Allow calendar access") { Task { await availability.requestAccess() } }
                    if availability.status == .denied {
                        Text("Access is off. Turn it on in System Settings > Privacy & Security > Calendars.")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Check only the calendar you book on.").font(.caption).foregroundStyle(.secondary)
                    ForEach(availability.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding(
                            get: { availability.selectedIDs.contains(calendar.calendarIdentifier) },
                            set: { on in
                                if on { availability.selectedIDs.insert(calendar.calendarIdentifier) }
                                else { availability.selectedIDs.remove(calendar.calendarIdentifier) }
                            }
                        )) {
                            Text("\(calendar.title)  ").font(.callout)
                            + Text(calendar.source.title).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func hourLabel(_ h: Int) -> String {
        "\((h + 11) % 12 + 1) \(h < 12 ? "AM" : "PM")"
    }
}
