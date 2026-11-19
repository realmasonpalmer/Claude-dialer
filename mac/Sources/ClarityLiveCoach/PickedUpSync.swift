import Foundation

/// Checks "Picked Up Cold Call" in Salesforce for a prospect reached in a real conversation.
/// Retries 3 times; if Salesforce is offline or still failing, it waits in a saved queue and is
/// sent after the next call. It never depends on which Chrome tab is open (the record Id says
/// Lead or Contact).
@MainActor
enum PickedUpSync {
    private static let key = "sfPickedUpPending"

    static var pending: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func mark(_ id: String) {
        guard Salesforce.objectFor(id: id) != nil else {
            ActivityLog.problem("Couldn't check Picked Up Cold Call for \(id): not a Lead or Contact Id")
            return
        }
        if !pending.contains(id) { pending.append(id) }
        flush()
    }

    /// Sends everything waiting. Safe to call often.
    static func flush() {
        guard Salesforce.isConnected else {
            if !pending.isEmpty { ActivityLog.add("Picked Up Cold Call: \(pending.count) waiting for Salesforce to connect") }
            return
        }
        for id in pending {
            Task { @MainActor in
                for (n, wait) in [0, 2, 4].enumerated() {
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    do {
                        try await Salesforce.markPickedUp(id)
                        pending.removeAll { $0 == id }
                        ActivityLog.add("Picked Up Cold Call checked for \(id)")
                        return
                    } catch {
                        if n == 2 { ActivityLog.problem("Couldn't check Picked Up Cold Call for \(id) after 3 tries: \(error.localizedDescription). It will retry after the next call.") }
                    }
                }
            }
        }
    }
}
