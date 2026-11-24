import Foundation
import Observation

/// Updates from this app's GitHub branch: checks every 2 minutes, and Update rebuilds and
/// reinstalls in the background (the install script quits and reopens the app when it's ready).
@Observable @MainActor
final class Updater {
    static let repo = "realmasonpalmer/Claude-dialer"
    static let branch = "claude/main-update"

    private(set) var available = false
    private(set) var updating = false
    var message: String?
    private var latest: String?

    private var installed: String? { UserDefaults.standard.string(forKey: "installedSHA") }
    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClarityDialer-update.log")
    }

    func run() async {
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(120))
        }
    }

    func check() async {
        // The branch's commit feed (no API rate limit). Newest commit first.
        var req = URLRequest(url: URL(string: "https://github.com/\(Self.repo)/commits/\(Self.branch).atom")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: #"Commit/[0-9a-f]{40}"#, options: .regularExpression) else { return }
        latest = String(text[r].dropFirst("Commit/".count))
        available = latest != installed
    }

    func update() {
        guard !updating, let sha = latest else { return }
        updating = true
        message = "Updating… the app reopens by itself in 1–3 minutes."
        let get = "https://raw.githubusercontent.com/\(Self.repo)/\(Self.branch)/dialer/scripts/get.sh"
        let cmd = "(curl -fsSL '\(get)' | SHA='\(sha)' BRANCH='\(Self.branch)' bash) || echo 'Update failed'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Detached, so it survives the app quitting for the reinstall.
        p.arguments = ["-c", "nohup bash -c \"\(cmd)\" >> '\(logURL.path)' 2>&1 &"]
        do { try p.run() } catch {
            updating = false
            message = "Couldn't start the update: \(error.localizedDescription)"
            return
        }
        Task { await watchLog(since: Date()) }
    }

    private func watchLog(since start: Date) async {
        let startSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        while updating {
            try? await Task.sleep(for: .seconds(5))
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if String(text.utf8.dropFirst(startSize)).map({ $0.contains("Update failed") }) == true {
                updating = false
                message = "The update didn't finish. Details: ~/Library/Logs/ClarityDialer-update.log"
            } else if Date().timeIntervalSince(start) > 600 {
                updating = false
                message = "The update is taking too long. Try again, or run the install command."
            }
        }
    }
}
