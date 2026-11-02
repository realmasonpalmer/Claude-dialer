import Foundation

/// A running log of what the app does (calls, checks, errors), saved on this Mac at
/// ~/Library/Logs/ClarityLiveCoach/activity.log. "Copy activity log" in Settings and tools
/// copies the latest part to paste for whoever is helping. Phone numbers are masked.
enum ActivityLog {
    private static let queue = DispatchQueue(label: "clarity.activity-log", qos: .utility)
    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var file: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClarityLiveCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.log")
    }

    static func add(_ text: String) {
        let stamp = stampFormat.string(from: Date())
        let line = "\(stamp)  \(mask(text))\n"
        queue.async {
            let url = file
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
            // Keep it small: when it passes 2 MB, keep the newest half.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000,
               let all = try? String(contentsOf: url, encoding: .utf8) {
                try? String(all.suffix(1_000_000)).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The newest lines, for pasting.
    static func recent(lines: Int = 400) -> String {
        queue.sync {
            let all = (try? String(contentsOf: file, encoding: .utf8)) ?? "(no log yet)"
            return all.components(separatedBy: "\n").suffix(lines).joined(separator: "\n")
        }
    }

    /// "+1 404-900-1040" -> "+1 ***-***-1040".
    private static func mask(_ text: String) -> String {
        let pattern = #"(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "***-***-$2")
    }
}
