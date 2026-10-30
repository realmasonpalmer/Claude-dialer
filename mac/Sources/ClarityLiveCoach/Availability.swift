import EventKit
import SwiftUI

/// Reads free time from the rep's Google Calendar, synced to macOS Calendar
/// (System Settings > Internet Accounts > Google). Recurring meetings are handled by macOS.
/// Only busy/free times are used; event titles and details are never sent anywhere.
@MainActor
final class Availability: ObservableObject {
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [EKCalendar] = []
    @Published var selectedIDs: Set<String> { didSet { save() } }
    @Published var startHour: Int { didSet { save() } }
    @Published var endHour: Int { didSet { save() } }
    @Published var meetingMinutes: Int { didSet { save() } }

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private var cached: (at: Date, text: String?)?

    var hasAccess: Bool { status == .fullAccess }

    init() {
        selectedIDs = Set(UserDefaults.standard.stringArray(forKey: "bookingCalendars") ?? [])
        startHour = UserDefaults.standard.object(forKey: "bookingStartHour") as? Int ?? 9
        endHour = UserDefaults.standard.object(forKey: "bookingEndHour") as? Int ?? 17
        meetingMinutes = UserDefaults.standard.object(forKey: "bookingMinutes") as? Int ?? 30
        loadCalendars()
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
        // First time: use your own Google calendars (the ones you can edit).
        if selectedIDs.isEmpty {
            let google = calendars.filter { $0.allowsContentModifications && $0.source.title.lowercased().contains("google") || $0.source.title.contains("@") }
            selectedIDs = Set((google.isEmpty ? calendars.filter(\.allowsContentModifications) : google).map(\.calendarIdentifier))
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

    func refresh() { cached = nil; objectWillChange.send() }

    private func computeOpenTimes() -> String? {
        let chosen = calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
        guard hasAccess, !chosen.isEmpty, endHour > startHour else { return nil }
        let cal = Calendar.current
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

            let events = store.events(matching: store.predicateForEvents(withStart: open, end: close, calendars: chosen))
            let busy = events
                .filter { !$0.isAllDay && $0.availability != .free }
                .map { ($0.startDate!, $0.endDate!) }

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
            let dayName = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            let ranges = windows.map { "\(time($0.0))-\(time($0.1))" }.joined(separator: ", ")
            lines.append("\(dayName): \(ranges)")
        }
        guard !lines.isEmpty else { return nil }
        let zone = TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier
        return "Times are in the rep's time zone (\(zone)). Meeting length: \(meetingMinutes) minutes.\n" + lines.joined(separator: "\n")
    }

    private func roundUpToHalfHour(_ date: Date, _ cal: Calendar) -> Date {
        let minute = cal.component(.minute, from: date)
        let add = minute == 0 || minute == 30 ? 0 : (minute < 30 ? 30 - minute : 60 - minute)
        let rounded = cal.date(byAdding: .minute, value: add, to: date)!
        return cal.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Booking calendar").font(.title2.weight(.semibold))
            Text("When you ask for the meeting, the coach offers real open times from your calendar.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !availability.hasAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Add your Google account to your Mac: System Settings > Internet Accounts > Add Account > Google. Turn on Calendars.")
                    Text("2. Then allow access here.")
                    Button("Allow calendar access") { Task { await availability.requestAccess() } }
                        .buttonStyle(.borderedProminent)
                    if availability.status == .denied {
                        Text("Access was turned off. Turn it on in System Settings > Privacy & Security > Calendars.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Check the calendars that show when you're busy:").font(.callout.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)

                HStack {
                    Stepper("Book from \(hourLabel(availability.startHour))", value: $availability.startHour, in: 6...12)
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
                Text(availability.openTimesText() ?? "No open times found. Check the calendars and hours above.")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 370)
        .onAppear { availability.loadCalendars() }
    }

    private func hourLabel(_ h: Int) -> String {
        "\((h + 11) % 12 + 1) \(h < 12 ? "AM" : "PM")"
    }
}
