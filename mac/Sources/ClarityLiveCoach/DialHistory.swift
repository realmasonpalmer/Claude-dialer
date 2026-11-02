import Foundation

/// Every call to each person, saved on this Mac. After the max number of tries with no
/// pickup (Settings: 3, 4 or 5), they come off the call list, like Not Quality Prospect.
enum DialHistory {
    struct Person: Codable {
        var dials: [Date] = []
        var pickups = 0
        var texts: [Date] = []
        var linkedIns: [Date] = []

        init() {}

        // Older saves don't have texts or LinkedIn yet: read what's there.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dials = try c.decodeIfPresent([Date].self, forKey: .dials) ?? []
            pickups = try c.decodeIfPresent(Int.self, forKey: .pickups) ?? 0
            texts = try c.decodeIfPresent([Date].self, forKey: .texts) ?? []
            linkedIns = try c.decodeIfPresent([Date].self, forKey: .linkedIns) ?? []
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

    static func logText(_ id: String) {
        var p = person(id)
        p.texts.append(Date())
        all[key(id)] = p
    }

    static func logLinkedIn(_ id: String) {
        var p = person(id)
        p.linkedIns.append(Date())
        all[key(id)] = p
    }

    /// Already texted / sent a LinkedIn note today: don't do it twice.
    static func textedToday(_ id: String) -> Bool { person(id).texts.contains { Calendar.current.isDateInToday($0) } }
    static func linkedInToday(_ id: String) -> Bool { person(id).linkedIns.contains { Calendar.current.isDateInToday($0) } }

    /// Called the max number of times and never picked up: off the list.
    static func isMaxed(_ id: String) -> Bool {
        let p = person(id)
        return maxDials > 0 && p.pickups == 0 && p.dials.count >= maxDials
    }

    static func resetAll() { all = [:] }
}
