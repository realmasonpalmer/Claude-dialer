import Foundation

/// Every answered call, kept for good: one small file per call with the full transcript.
/// ~/Library/Application Support/Clarity Live Coach/Calls/2026-11-17/153012-<id>.json
/// The Script Lab reads these so Claude can study real calls, not just short notes.
enum CallLibrary {
    struct Entry: Codable {
        var id: UUID
        var date: Date
        var campaignID: UUID
        var person: String?
        var score: Int
        var goal: Bool
        var stages: [String]
        var transcript: String
    }

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clarity Live Coach/Calls", isDirectory: true)
    }()

    private static let queue = DispatchQueue(label: "clarity.call-library", qos: .utility)

    static func save(_ e: Entry) {
        queue.async {
            let day = e.date.formatted(.iso8601.year().month().day())
            let dir = folder.appendingPathComponent(day, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "HHmmss"
            let url = dir.appendingPathComponent("\(f.string(from: e.date))-\(e.id.uuidString.prefix(8)).json")
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
            if let data = try? enc.encode(e) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// The newest calls for a call list, newest last.
    static func recent(campaignID: UUID, limit: Int) -> [Entry] {
        queue.sync {
            let fm = FileManager.default
            let days = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var out: [Entry] = []
            for day in days {
                let files = ((try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
                for f in files {
                    guard let d = try? Data(contentsOf: f), let e = try? dec.decode(Entry.self, from: d), e.campaignID == campaignID else { continue }
                    out.append(e)
                    if out.count >= limit { return out.reversed() }
                }
            }
            return out.reversed()
        }
    }
}
