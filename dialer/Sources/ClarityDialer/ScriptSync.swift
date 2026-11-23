import Foundation
import Observation

/// Keeps scripts the same for everyone: each script is a Salesforce File shared with the company.
/// Saving here publishes a new version; every app pulls the newest versions at launch and every
/// 2 minutes. Newest edit wins.
@Observable @MainActor
final class ScriptSync {
    private let store: Store
    private(set) var status = ""
    private var running = false

    init(store: Store) { self.store = store }

    func run() async {
        while !Task.isCancelled {
            await syncNow()
            try? await Task.sleep(for: .seconds(120))
        }
    }

    /// Saves an edit locally, then publishes it.
    func save(_ id: UUID, name: String, body: String) {
        guard let i = store.scripts.firstIndex(where: { $0.id == id }) else { return }
        store.scripts[i].name = name.trimmed.isEmpty ? "Script" : name.trimmed
        store.scripts[i].body = body
        store.scripts[i].updatedAt = Date()
        store.scripts[i].needsPublish = true
        Task { await syncNow() }
    }

    func syncNow() async {
        guard Salesforce.isConnected, !running else { return }
        running = true
        defer { running = false }
        // 1. Push local edits.
        for s in store.scripts where s.needsPublish {
            do {
                let doc = try await Salesforce.publish(s)
                if let i = store.scripts.firstIndex(where: { $0.id == s.id }) {
                    store.scripts[i].sharedDocID = doc
                    // Edited again while sending? Leave it marked for the next pass.
                    if store.scripts[i].body == s.body, store.scripts[i].name == s.name { store.scripts[i].needsPublish = false }
                }
            } catch {
                status = "Script saved here; sharing will retry: \(error.localizedDescription)"
                return
            }
        }
        // 2. Pull everyone's latest.
        do {
            for remote in try await Salesforce.sharedScripts() {
                if let i = store.scripts.firstIndex(where: { $0.sharedDocID == remote.docID }) {
                    let local = store.scripts[i]
                    if !local.needsPublish, remote.modified > local.updatedAt, local.body != remote.body || local.name != remote.name {
                        store.scripts[i].body = remote.body
                        store.scripts[i].name = remote.name
                        store.scripts[i].updatedAt = remote.modified
                    }
                } else {
                    var s = Script(name: remote.name, body: remote.body)
                    s.sharedDocID = remote.docID
                    s.updatedAt = remote.modified
                    // First run: a starter script nobody touched gives way to the team's script.
                    if store.scripts.count == 1, store.scripts[0].sharedDocID == nil,
                       Self.isStarter(store.scripts[0]) {
                        store.scripts = [s]
                        store.selectedScriptID = s.id
                    } else {
                        store.scripts.append(s)
                    }
                }
            }
            status = "Scripts up to date"
        } catch {
            status = "Couldn't load shared scripts: \(error.localizedDescription)"
        }
        // 3. Scripts that were never shared (made before sharing existed): share them now.
        let unshared = store.scripts.indices.filter {
            store.scripts[$0].sharedDocID == nil && !store.scripts[$0].needsPublish && !Self.isStarter(store.scripts[$0])
        }
        if !unshared.isEmpty {
            for i in unshared { store.scripts[i].needsPublish = true }
            running = false
            await syncNow()
        }
    }

    /// The placeholder script a fresh install starts with. Never shared.
    static func isStarter(_ s: Script) -> Bool {
        s.updatedAt == .distantPast && s.body.contains("Paste your script here")
    }
}
