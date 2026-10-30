import Foundation

/// Reads busy times straight from a Google Calendar's iCal (.ics) address,
/// e.g. the boss's calendar. No Google sign-in and no macOS Calendar setup needed.
enum CalendarFeed {
    struct Busy {
        let start: Date
        let end: Date
    }

    struct Result {
        let busy: [Busy]
        let timeZone: TimeZone?   // the calendar's own time zone, if it says
        let eventCount: Int
    }

    struct FeedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Turns what the rep pastes into an .ics address:
    /// - an embed link: calendar.google.com/calendar/embed?src=oliver%40company.com
    /// - an email or calendar ID: oliver@company.com
    /// - a public or secret iCal address (https:// or webcal://)
    static func feedURL(from input: String) -> URL? {
        let text = input.trimmed
        if text.isEmpty { return nil }
        if text.lowercased().hasPrefix("webcal://") {
            return URL(string: "https://" + text.dropFirst("webcal://".count))
        }
        if let components = URLComponents(string: text), components.path.contains("/calendar/embed"),
           let src = components.queryItems?.first(where: { $0.name == "src" })?.value {
            return publicURL(for: src)
        }
        if text.lowercased().hasPrefix("http") { return URL(string: text) }
        if text.contains("@"), !text.contains(" ") { return publicURL(for: text) }
        return nil
    }

    private static func publicURL(for calendarID: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "@/")
        guard let id = calendarID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://calendar.google.com/calendar/ical/\(id)/public/basic.ics")
    }

    /// Downloads the feed and returns busy times between now and `days` from now.
    static func load(_ url: URL, days: Int = 14) async throws -> Result {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else {
            throw FeedError(message: code == 404 || code == 403
                ? "This calendar isn't shared by link yet. Its owner needs to turn on free/busy sharing (steps below)."
                : "Couldn't read the calendar (error \(code)). Check the address.")
        }
        let now = Date()
        return parse(text, from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(Double(days) * 86_400))
    }

    // MARK: - Parsing

    private struct Event {
        var uid = ""
        var start: Date?
        var end: Date?
        var duration: TimeInterval?
        var allDay = false
        var rrule: [String: String] = [:]
        var exdates: Set<Date> = []
        var recurrenceID: Date?
        var cancelled = false
        var transparent = false
        var timeZone: TimeZone = .current
    }

    static func parse(_ ics: String, from windowStart: Date, to windowEnd: Date) -> Result {
        // Unfold long lines (a line starting with a space continues the previous one).
        let unfolded = ics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var calendarZone: TimeZone?
        var events: [Event] = []
        var current: Event?

        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if line == "BEGIN:VEVENT" { current = Event(); continue }
            if line == "END:VEVENT" { if let e = current { events.append(e) }; current = nil; continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon]
            let value = String(line[line.index(after: colon)...])
            let parts = head.split(separator: ";").map(String.init)
            let name = parts.first?.uppercased() ?? ""
            var params: [String: String] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }

            if current == nil {
                if name == "X-WR-TIMEZONE" { calendarZone = TimeZone(identifier: value) }
                continue
            }
            switch name {
            case "UID": current?.uid = value
            case "DTSTART":
                let (date, allDay, zone) = parseDate(value, params, fallback: calendarZone)
                current?.start = date
                current?.allDay = allDay
                if let zone { current?.timeZone = zone }
            case "DTEND": current?.end = parseDate(value, params, fallback: calendarZone).0
            case "DURATION": current?.duration = parseDuration(value)
            case "RRULE":
                for pair in value.split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { current?.rrule[kv[0].uppercased()] = kv[1] }
                }
            case "EXDATE":
                for item in value.split(separator: ",") {
                    if let d = parseDate(String(item), params, fallback: calendarZone).0 { current?.exdates.insert(d) }
                }
            case "RECURRENCE-ID": current?.recurrenceID = parseDate(value, params, fallback: calendarZone).0
            case "STATUS": current?.cancelled = value.uppercased() == "CANCELLED"
            case "TRANSP": current?.transparent = value.uppercased() == "TRANSPARENT"
            default: break
            }
        }

        // Moved or cancelled single instances replace their original slot in the series.
        var overridden: [String: Set<Date>] = [:]
        for e in events where e.recurrenceID != nil {
            overridden[e.uid, default: []].insert(e.recurrenceID!)
        }

        var busy: [Busy] = []
        for e in events {
            guard let start = e.start, !e.allDay, !e.cancelled, !e.transparent else { continue }
            let length = e.end.map { $0.timeIntervalSince(start) } ?? e.duration ?? 3600
            guard length > 0 else { continue }
            let starts: [Date]
            if e.rrule.isEmpty || e.recurrenceID != nil {
                starts = [start]
            } else {
                let skip = e.exdates.union(overridden[e.uid] ?? [])
                starts = expand(e.rrule, from: start, zone: e.timeZone, until: windowEnd).filter { !skip.contains($0) }
            }
            for s in starts where s < windowEnd && s.addingTimeInterval(length) > windowStart {
                busy.append(Busy(start: s, end: s.addingTimeInterval(length)))
            }
        }
        return Result(busy: busy.sorted { $0.start < $1.start }, timeZone: calendarZone, eventCount: events.count)
    }

    /// Dates like 20261103T170000Z, 20261103T100000 with TZID, or 20261103 (all day).
    private static func parseDate(_ value: String, _ params: [String: String], fallback: TimeZone?) -> (Date?, Bool, TimeZone?) {
        let v = value.trimmed
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || v.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = fallback ?? .current
            return (formatter.date(from: String(v.prefix(8))), true, nil)
        }
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        var zone: TimeZone?
        if v.hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC")
        } else if let id = params["TZID"] {
            zone = TimeZone(identifier: id) ?? fallback
        } else {
            zone = fallback
        }
        formatter.timeZone = zone ?? .current
        return (formatter.date(from: String(v.prefix(15))), false, zone)
    }

    /// Durations like PT30M, PT1H, P1D.
    private static func parseDuration(_ value: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        for ch in value.uppercased() {
            if ch.isNumber { number.append(ch); continue }
            let n = Double(number) ?? 0
            switch ch {
            case "W": total += n * 604_800
            case "D": total += n * 86_400
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
            number = ""
        }
        return total > 0 ? total : nil
    }

    // MARK: - Repeating events

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// Expands a repeat rule (daily, weekly, monthly, yearly) into start times up to `until`.
    private static func expand(_ rule: [String: String], from start: Date, zone: TimeZone, until windowEnd: Date) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let freq = rule["FREQ"]?.uppercased() ?? ""
        let interval = max(1, Int(rule["INTERVAL"] ?? "1") ?? 1)
        let count = rule["COUNT"].flatMap { Int($0) }
        let untilDate = rule["UNTIL"].flatMap { parseDate($0, [:], fallback: zone).0 }
        let last = min(untilDate ?? windowEnd, windowEnd)
        let time = cal.dateComponents([.hour, .minute, .second], from: start)
        let byDay = (rule["BYDAY"] ?? "").split(separator: ",").map { String($0).uppercased() }

        var results: [Date] = []
        var produced = 0
        func add(_ d: Date) -> Bool {
            // false = stop
            if d < start { return true }
            if let count, produced >= count { return false }
            if d > last { return false }
            produced += 1
            results.append(d)
            return true
        }
        func at(_ day: Date) -> Date? {
            cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
        }

        var step = 0
        let maxSteps = 4000
        switch freq {
        case "DAILY":
            while step < maxSteps, let d = cal.date(byAdding: .day, value: step * interval, to: start), add(d) { step += 1 }
        case "WEEKLY":
            let days = byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.compactMap { weekdays[String($0.suffix(2))] }
            let weekStart = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            outer: while step < maxSteps {
                guard let week = cal.date(byAdding: .weekOfYear, value: step * interval, to: weekStart) else { break }
                if week > last { break }
                for wd in days.sorted() {
                    let offset = (wd - cal.component(.weekday, from: week) + 7) % 7
                    guard let day = cal.date(byAdding: .day, value: offset, to: week), let d = at(day) else { continue }
                    if !add(d) { break outer }
                }
                step += 1
            }
        case "MONTHLY":
            let monthStart = cal.dateInterval(of: .month, for: start)?.start ?? start
            outer: while step < maxSteps {
                guard let month = cal.date(byAdding: .month, value: step * interval, to: monthStart) else { break }
                if month > last { break }
                var days: [Date] = []
                if let first = byDay.first, first.count > 2, let wd = weekdays[String(first.suffix(2))], let nth = Int(first.dropLast(2)) {
                    // e.g. 2TU = second Tuesday, -1FR = last Friday
                    var dc = cal.dateComponents([.year, .month], from: month)
                    dc.weekday = wd
                    dc.weekdayOrdinal = nth
                    if let d = cal.date(from: dc) { days.append(d) }
                } else {
                    var dc = cal.dateComponents([.year, .month], from: month)
                    dc.day = Int(rule["BYMONTHDAY"] ?? "") ?? cal.component(.day, from: start)
                    if let d = cal.date(from: dc), cal.component(.month, from: d) == dc.month { days.append(d) }
                }
                for day in days {
                    guard let d = at(day) else { continue }
                    if !add(d) { break outer }
                }
                step += 1
            }
        case "YEARLY":
            while step < maxSteps, let d = cal.date(byAdding: .year, value: step * interval, to: start), add(d) { step += 1 }
        default:
            results = [start]
        }
        return results
    }
}
