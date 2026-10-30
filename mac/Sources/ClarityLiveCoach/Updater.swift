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
    func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/commits/\(Self.branch)") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else { return }
        latestSHA = sha
        updateAvailable = sha != installedSHA
    }

    /// Starts the update. The app keeps working while it builds, then closes and reopens.
    func update() {
        guard !updating else { return }
        let sha = latestSHA ?? ""
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
        } catch {
            message = "Couldn't start the update: \(error.localizedDescription)"
        }
    }
}
