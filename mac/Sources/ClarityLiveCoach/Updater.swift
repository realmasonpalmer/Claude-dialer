import AppKit

/// Updates the app from GitHub without Terminal: downloads the latest code, builds it in the
/// background, and the install script closes and reopens the app when it's ready.
/// Needs Apple's free command line tools (already installed for the first install).
@MainActor
final class Updater: ObservableObject {
    static let repo = "realmasonpalmer/claude-dialer"
    static let branch = "claude/confident-gates-ji8r2l"

    @Published private(set) var updateAvailable = false
    @Published private(set) var updating = false
    @Published private(set) var message: String?
    private var latestSHA: String?

    private var installedSHA: String? { UserDefaults.standard.string(forKey: "installedSHA") }

    /// Asks GitHub for the newest version (at launch, then every 10 minutes).
    /// - Parameter byHand: the rep clicked "Check for updates", so always say what happened.
    func check(byHand: Bool = false) async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/commits/\(Self.branch)") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            if byHand { message = "Couldn't reach GitHub. Check your internet and try again." }
            return
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else {
            if byHand {
                message = code == 403 || code == 429
                    ? "GitHub says too many checks. Try again in an hour."
                    : "Couldn't check for updates (GitHub error \(code))."
            }
            return
        }
        latestSHA = sha
        updateAvailable = sha != installedSHA
        if byHand { message = updateAvailable ? "An update is ready. Click Update at the top." : "You have the newest version." }
    }

    /// Reads the update log while it runs, so a failed update says so instead of "Updating" forever.
    private func watch(log: URL, startedAt: Date) {
        let startSize = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.updating else { return }
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                let new = text.utf8.count > startSize ? String(text.dropFirst(startSize)) : text
                if let line = new.components(separatedBy: "\n").first(where: { $0.hasPrefix("Update failed") }) {
                    self.updating = false
                    self.message = "The update didn't finish (\(line.replacingOccurrences(of: "Update failed: ", with: ""))). The app still works. Click Update to try again."
                    return
                }
                if Date().timeIntervalSince(startedAt) > 600 {
                    self.updating = false
                    self.message = "The update is taking too long. Quit the app (Command-Q) and open it again."
                    return
                }
            }
        }
    }

    /// Starts the update. The app keeps working while it builds, then closes and reopens.
    func update() {
        guard !updating else { return }
        let sha = latestSHA ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let script = caches.appendingPathComponent("ClarityLiveCoach-update.sh")
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClarityLiveCoach-update.log")
        let zip = "https://github.com/\(Self.repo)/archive/refs/heads/\(Self.branch).zip"
        let body = """
        #!/bin/bash
        exec >>"\(log.path)" 2>&1
        echo "=== Update started $(date)"
        fail() {
            echo "Update failed: $1"
            osascript -e 'display notification "The update did not finish. The app still works. Ask for help with ~/Library/Logs/ClarityLiveCoach-update.log" with title "Clarity Live Coach"'
            exit 1
        }
        WORK="$HOME/Library/Caches/ClarityLiveCoach-update"
        rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK" || fail "folder"
        curl -fsSL -o code.zip "\(zip)" || fail "download"
        ditto -x -k code.zip . || fail "unzip"
        DIR="$(find . -maxdepth 2 -type d -name mac | head -1)"
        [ -n "$DIR" ] || fail "no mac folder in download"
        cd "$DIR" || fail "cd"
        bash scripts/install.sh || fail "build"
        defaults write io.clarityconsulting.livecoach installedSHA "\(sha)"
        # If the old copy didn't close (macOS can block the polite quit), close it and open the new one.
        sleep 3
        if kill -0 \(pid) 2>/dev/null; then
            echo "Old copy still open: closing it."
            kill \(pid) 2>/dev/null
            sleep 2
            kill -9 \(pid) 2>/dev/null
            open "/Applications/Clarity Live Coach.app"
        fi
        echo "=== Update finished $(date)"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            // Run detached, so it keeps going when the install script closes this app.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "nohup /bin/bash '\(script.path)' >/dev/null 2>&1 &"]
            try process.run()
            updating = true
            message = "Updating. Keep working: the app closes and reopens by itself in about 2 minutes."
            watch(log: log, startedAt: Date())
        } catch {
            message = "Couldn't start the update: \(error.localizedDescription)"
        }
    }
}
