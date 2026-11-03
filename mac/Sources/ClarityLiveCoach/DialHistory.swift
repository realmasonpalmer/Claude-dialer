import Foundation

/// Every call to each person, saved on this Mac. After the max number of tries with no
/// pickup (Settings: 3, 4 or 5), they come off the call list, like Not Quality Prospect.
enum DialHistory {
    struct Person: Codable {
        var dials: [Date] = []
        var pickups = 0
        var texts: [Date] = []
        /// The words of every text sent to them, oldest first.
        var textBodies: [String] = []
        var linkedIns: [Date] = []
        var linkedInMessages: [Date] = []
        /// The words of every LinkedIn message copied for them, oldest first.
        var linkedInMessageBodies: [String] = []
        /// Voicemails left for them (when, and the words), oldest first.
        var voicemails: [Date] = []
        var voicemailBodies: [String] = []
        /// The carrier said the number doesn't work.
        var badNumber = false
        /// Calls that ended in seconds with nobody on the line (beeping tone, no connection).
        var failedConnects = 0

        init() {}

        // Older saves don't have texts or LinkedIn yet: read what's there.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dials = try c.decodeIfPresent([Date].self, forKey: .dials) ?? []
            pickups = try c.decodeIfPresent(Int.self, forKey: .pickups) ?? 0
            texts = try c.decodeIfPresent([Date].self, forKey: .texts) ?? []
            textBodies = try c.decodeIfPresent([String].self, forKey: .textBodies) ?? []
            linkedIns = try c.decodeIfPresent([Date].self, forKey: .linkedIns) ?? []
            linkedInMessages = try c.decodeIfPresent([Date].self, forKey: .linkedInMessages) ?? []
            linkedInMessageBodies = try c.decodeIfPresent([String].self, forKey: .linkedInMessageBodies) ?? []
            voicemails = try c.decodeIfPresent([Date].self, forKey: .voicemails) ?? []
            voicemailBodies = try c.decodeIfPresent([String].self, forKey: .voicemailBodies) ?? []
            badNumber = try c.decodeIfPresent(Bool.self, forKey: .badNumber) ?? false
            failedConnects = try c.decodeIfPresent(Int.self, forKey: .failedConnects) ?? 0
        }
    }

    private static var cache: [String: Person]?

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClarityLiveCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dial-history.json")
    }

    private static var all: [String: Person] {
        get {
            if let cache { return cache }
            let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Person].self, from: $0) } ?? [:]
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: file, options: .atomic) }
        }
    }

    private static func key(_ id: String) -> String { String(id.prefix(15)) }

    /// 3, 4 or 5. 0 = never take anyone off for this.
    static var maxDials: Int {
        get { UserDefaults.standard.object(forKey: "maxDials") as? Int ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: "maxDials") }
    }

    static func person(_ id: String) -> Person { all[key(id)] ?? Person() }

    static func logDial(_ id: String) {
        var p = person(id)
        p.dials.append(Date())
        all[key(id)] = p
    }

    static func logPickup(_ id: String) {
        var p = person(id)
        p.pickups += 1
        all[key(id)] = p
    }

    static func logText(_ id: String, body: String = "") {
        var p = person(id)
        p.texts.append(Date())
        if !body.isEmpty { p.textBodies.append(body) }
        all[key(id)] = p
    }

    /// Texts already sent to them, newest last (for writing a different one).
    static func sentTexts(_ id: String) -> [String] { person(id).textBodies }

    /// True if this text is the same as one already sent to them (ignoring case and spacing).
    static func alreadySent(_ body: String, to id: String) -> Bool {
        let norm = { (t: String) in t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }
        let mine = norm(body)
        return person(id).textBodies.contains { norm($0) == mine }
    }

    static func logLinkedIn(_ id: String) {
        var p = person(id)
        p.linkedIns.append(Date())
        all[key(id)] = p
    }

    static func logLinkedInMessage(_ id: String, body: String = "") {
        var p = person(id)
        p.linkedInMessages.append(Date())
        if !body.isEmpty { p.linkedInMessageBodies.append(body) }
        all[key(id)] = p
    }

    static func logVoicemail(_ id: String, body: String) {
        var p = person(id)
        p.voicemails.append(Date())
        if !body.isEmpty { p.voicemailBodies.append(body) }
        all[key(id)] = p
    }

    /// Everything we've done with this person, in plain words, for writing the next voicemail.
    static func historySummary(_ id: String) -> String {
        let p = person(id)
        func when(_ d: Date?) -> String {
            guard let d else { return "" }
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                                       to: Calendar.current.startOfDay(for: Date())).day ?? 0
            return days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        }
        var lines: [String] = []
        if !p.dials.isEmpty { lines.append("Calls so far: \(p.dials.count) (first \(when(p.dials.first))).") }
        if !p.voicemails.isEmpty {
            lines.append("Voicemails already left: \(p.voicemails.count), latest \(when(p.voicemails.last)).")
            for v in p.voicemailBodies.suffix(3) { lines.append("  Earlier voicemail: \(v)") }
        }
        if !p.texts.isEmpty {
            lines.append("Texts already sent: \(p.texts.count), latest \(when(p.texts.last)). They have the rep's number.")
        }
        if !p.linkedIns.isEmpty { lines.append("LinkedIn connection note sent \(when(p.linkedIns.last)).") }
        if !p.linkedInMessages.isEmpty { lines.append("LinkedIn message sent \(when(p.linkedInMessages.last)).") }
        return lines.joined(separator: "\n")
    }

    /// LinkedIn messages already sent to them, newest last.
    static func sentLinkedInMessages(_ id: String) -> [String] { person(id).linkedInMessageBodies }

    static func linkedInMessageToday(_ id: String) -> Bool { person(id).linkedInMessages.contains { Calendar.current.isDateInToday($0) } }

    /// Already texted / sent a LinkedIn note today: don't do it twice.
    static func textedToday(_ id: String) -> Bool { person(id).texts.contains { Calendar.current.isDateInToday($0) } }
    static func linkedInToday(_ id: String) -> Bool { person(id).linkedIns.contains { Calendar.current.isDateInToday($0) } }

    /// Called the max number of times and never picked up: off the list.
    static func isMaxed(_ id: String) -> Bool {
        let p = person(id)
        if p.badNumber || p.failedConnects >= 2 { return true }
        return maxDials > 0 && p.pickups == 0 && p.dials.count >= maxDials
    }

    /// Counts a call that didn't connect. Returns the total. Two = off the list.
    @discardableResult
    static func logFailedConnect(_ id: String) -> Int {
        var p = person(id)
        p.failedConnects += 1
        all[key(id)] = p
        return p.failedConnects
    }

    static func markBadNumber(_ id: String) {
        var p = person(id)
        p.badNumber = true
        all[key(id)] = p
    }

    static func resetAll() { all = [:] }
}
