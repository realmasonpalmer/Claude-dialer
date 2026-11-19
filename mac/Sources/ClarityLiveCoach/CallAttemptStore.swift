import CoachCore
import Foundation

/// Every call attempt on this Mac, saved as it happens (attempts.json). A call still open when the
/// app quit is finished on the next launch from what was saved, so no dial is lost or counted twice.
@MainActor
final class CallAttemptStore {
    static let shared = CallAttemptStore()
    private(set) var attempts: [CallAttempt] = []

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClarityLiveCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("attempts.json")
    }

    private init() {
        guard FileManager.default.fileExists(atPath: Self.file.path) else { return }
        do {
            attempts = try JSONDecoder().decode([CallAttempt].self, from: Data(contentsOf: Self.file))
        } catch {
            ActivityLog.problem("Call records: couldn't read attempts.json (\(error.localizedDescription)). Starting a new file.")
        }
    }

    /// Saves the attempt (new or updated) by its id.
    func upsert(_ a: CallAttempt) {
        if let i = attempts.lastIndex(where: { $0.attemptID == a.attemptID }) { attempts[i] = a } else { attempts.append(a) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -730, to: Date()) ?? .distantPast
        if attempts.first.map({ $0.startedAt < cutoff }) == true { attempts.removeAll { $0.startedAt < cutoff } }
        save()
    }

    /// Calls left open by a quit or crash: finished now from what was saved.
    func orphans() -> [CallAttempt] {
        var out: [CallAttempt] = []
        for var a in attempts where !a.finalized {
            let last = ([a.placedAt].compactMap { $0 } + a.heard.map(\.at) + a.repSaid.map(\.at)).max() ?? a.startedAt
            a.finalize(endedAt: last, source: "recovered after app quit")
            upsert(a)
            out.append(a)
        }
        return out
    }

    /// Finished attempts since a time, in one campaign (nil = all).
    func finished(since start: Date, campaign: String?) -> [CallAttempt] {
        attempts.filter { $0.finalized && $0.startedAt >= start && (campaign == nil || $0.campaign == campaign) }
    }

    /// This person already had a voicemail counted today (so "Call twice" doesn't count it twice).
    func voicemailCountedToday(lead: String, except id: String) -> Bool {
        attempts.contains { $0.attemptID != id && $0.leadID == lead && $0.outcome == .voicemail && Calendar.current.isDateInToday($0.startedAt) }
    }

    private func save() {
        do {
            try JSONEncoder().encode(attempts).write(to: Self.file, options: .atomic)
        } catch {
            ActivityLog.problem("Call records: couldn't save attempts.json (\(error.localizedDescription))")
        }
    }
}
