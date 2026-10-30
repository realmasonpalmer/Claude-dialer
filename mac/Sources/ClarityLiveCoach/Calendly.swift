import Foundation

/// Reads open booking times from a public Calendly link, e.g. calendly.com/oliver/30min.
/// It uses the same public data the Calendly booking page loads in the browser.
/// That isn't an official API, so if Calendly changes it, this shows a clear error.
enum Calendly {
    struct Slots {
        let starts: [Date]
        let minutes: Int?
        let meetingName: String?
    }

    static func isLink(_ input: String) -> Bool {
        input.lowercased().contains("calendly.com/")
    }

    /// calendly.com/{person or team}/{meeting type}. The meeting type is optional.
    static func slugs(from input: String) -> (profile: String, event: String?)? {
        var text = input.trimmed
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let profile = parts.first else { return nil }
        return (profile, parts.count >= 2 ? parts[1] : nil)
    }

    /// For a page like calendly.com/clarity_consulting: picks the first public meeting type.
    private static func firstMeetingType(profile: String) async throws -> (uuid: String, minutes: Int?, name: String?) {
        let url = URL(string: "https://calendly.com/api/booking/profiles/\(profile)/event_types")!
        let json = try await getAny(url)
        var types: [[String: Any]] = []
        func collect(_ value: Any) {
            if let dict = value as? [String: Any] {
                if dict["uuid"] is String, dict["slug"] is String { types.append(dict) }
                for (_, child) in dict { collect(child) }
            } else if let list = value as? [Any] {
                list.forEach(collect)
            }
        }
        collect(json)
        let open = types.filter { ($0["secret"] as? Bool) != true && ($0["active"] as? Bool) != false }
        guard let pick = open.first ?? types.first, let uuid = pick["uuid"] as? String else {
            throw CalendarFeed.FeedError(message: "No bookable meetings found on that Calendly page.")
        }
        return (uuid, pick["duration"] as? Int, pick["name"] as? String)
    }

    static func load(_ input: String, days: Int = 14) async throws -> Slots {
        guard let parsed = slugs(from: input) else {
            throw CalendarFeed.FeedError(message: "That doesn't look like a Calendly link.")
        }
        let profile = parsed.profile
        // 1. Find the meeting type: the one in the link, or the page's first public one.
        var uuid = ""
        var minutes: Int?
        var name: String?
        if let event = parsed.event {
            var lookup = URLComponents(string: "https://calendly.com/api/booking/event_types/lookup")!
            lookup.queryItems = [.init(name: "event_type_slug", value: event), .init(name: "profile_slug", value: profile)]
            let info = try await getJSON(lookup.url!)
            let resource = (info["resource"] as? [String: Any]) ?? info
            guard let found = resource["uuid"] as? String else {
                throw CalendarFeed.FeedError(message: "Couldn't find that Calendly meeting. Check the link.")
            }
            uuid = found
            minutes = resource["duration"] as? Int
            name = resource["name"] as? String
        } else {
            let first = try await firstMeetingType(profile: profile)
            uuid = first.uuid
            minutes = first.minutes
            name = first.name
        }

        // 2. Ask for open times, a week at a time.
        let zone = TimeZone.current.identifier
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        var starts: [Date] = []
        var from = Date()
        let end = Date().addingTimeInterval(Double(days) * 86_400)
        while from < end {
            let to = min(from.addingTimeInterval(6 * 86_400), end)
            var range = URLComponents(string: "https://calendly.com/api/booking/event_types/\(uuid)/calendar/range")!
            range.queryItems = [
                .init(name: "timezone", value: zone),
                .init(name: "diagnostics", value: "false"),
                .init(name: "range_start", value: dayFormat.string(from: from)),
                .init(name: "range_end", value: dayFormat.string(from: to)),
            ]
            let json = try await getJSON(range.url!)
            starts += availableStarts(in: json)
            from = to.addingTimeInterval(86_400)
        }
        let now = Date()
        return Slots(starts: Array(Set(starts)).filter { $0 > now }.sorted(), minutes: minutes, meetingName: name)
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        guard let dict = try await getAny(url) as? [String: Any] else {
            throw CalendarFeed.FeedError(message: "Calendly sent an unexpected answer. It may have changed its page.")
        }
        return dict
    }

    private static func getAny(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) else {
            throw CalendarFeed.FeedError(message: code == 404
                ? "Couldn't find that Calendly link. Check it, or try the link for one meeting type."
                : "Couldn't read Calendly (error \(code)). If this keeps happening, Calendly may have changed its page.")
        }
        return json
    }

    /// Finds every open slot anywhere in the answer: objects with a start_time whose status is "available".
    private static func availableStarts(in value: Any) -> [Date] {
        var found: [Date] = []
        if let dict = value as? [String: Any] {
            if let start = dict["start_time"] as? String,
               (dict["status"] as? String).map({ $0 == "available" }) ?? true,
               let date = parseISO(start) {
                found.append(date)
            }
            for (_, child) in dict { found += availableStarts(in: child) }
        } else if let list = value as? [Any] {
            for child in list { found += availableStarts(in: child) }
        }
        return found
    }

    private static func parseISO(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
