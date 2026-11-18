import AppKit
import Foundation

/// One structured, millisecond-accurate timeline per call, for an AI (or a person) to reconstruct
/// exactly what happened and why. JSON Lines: one event per line, written in the background so it
/// never slows the coach.
///
/// Every event has:
///   seq          order within the call
///   wall         wall-clock time, ms precision (for matching against other services' logs)
///   t_ms         monotonic ms since the call started (use this for latency math)
///   call         call ID;  turn: transcript turn number;  req: Claude request ID;
///   sug: suggestion ID (= the request ID that made it);  mem: memory version (call summary)
///   type         what happened (see Export README for the full list)
///   data         the actual inputs, outputs and the reason for the decision
///
/// Files: ~/Library/Logs/ClarityLiveCoach/calls/<date>/<time>-<call>.jsonl
/// Phone numbers are masked. Transcripts are kept (they stay on this Mac).
@MainActor
enum CallTrace {
    nonisolated private static let queue = DispatchQueue(label: "clarity.call-trace", qos: .utility)
    private static var file: URL?
    private static var start = ContinuousClock.now
    private static var seq = 0
    static private(set) var callID = ""
    static var turn = 0
    static var memVersion = 0
    static private(set) var lastFile: URL?

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClarityLiveCoach/calls", isDirectory: true)
    }

    static func beginCall(lead: String?, attempt: Int) {
        callID = String(UUID().uuidString.prefix(8))
        start = .now
        seq = 0
        turn = 0
        memVersion = 0
        let day = Date().formatted(.iso8601.year().month().day())
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        let dir = folder.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("\(f.string(from: Date()))-\(callID).jsonl")
        lastFile = file
        event("call.start", ["lead": lead ?? "?", "attempt": attempt])
    }

    static func endCall(_ data: [String: Any]) {
        event("call.end", data)
        file = nil
    }

    /// Logs one event. Values must be JSON types (String, numbers, Bool, arrays, dictionaries).
    static func event(_ type: String, _ data: [String: Any] = [:], req: Int? = nil, sug: Int? = nil) {
        guard let file else { return }
        seq += 1
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
            + Double((ContinuousClock.now - start).components.seconds) * 1000
        var row: [String: Any] = [
            "seq": seq, "wall": Self.wall.string(from: Date()), "t_ms": Int(ms.rounded()),
            "call": callID, "turn": turn, "mem": memVersion, "type": type, "data": mask(data),
        ]
        if let req { row["req"] = req }
        if let sug { row["sug"] = sug }
        queue.async {
            guard let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(line); h.write(Data("\n".utf8)); try? h.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: file)
            }
        }
    }

    private static let wall: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"; return f
    }()

    private static func mask(_ d: [String: Any]) -> [String: Any] {
        d.mapValues { v in (v as? String).map(ActivityLog.mask) ?? v }
    }

    // MARK: Export

    /// Builds an AI-readable bundle for the last call (or a given trace): the trace, a README that
    /// explains every event and points at the code, and the activity log around it. Opens the folder.
    static func exportLast() {
        queue.sync {} // write every pending event first, so the end of the call is in the copy (M5)
        guard let src = lastFile ?? latestTrace() else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Clarity Call Diagnostics/\(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("trace.jsonl"))
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? ActivityLog.recent(lines: 600).write(to: dir.appendingPathComponent("activity-log.txt"), atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(dir)
    }

    private static func latestTrace() -> URL? {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for d in days {
            if let f = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first { return f }
        }
        return nil
    }

    static let readme = """
    # Clarity Live Coach: call diagnostic bundle

    Give this folder to an AI and ask it to find the root cause of slow or poor coaching.

    ## Files
    - trace.jsonl: one JSON event per line, in order. The complete timeline of one call.
    - activity-log.txt: the app's plain log around this call (other calls too).

    ## Fields on every event
    seq (order), wall (clock time, ms), t_ms (ms since call start, monotonic: use for latency),
    call (call ID), turn (transcript turn #), req (Claude request #), sug (suggestion # = its request #),
    mem (call-summary version the coach knew), type, data.

    ## Event types (and where they come from in the code: mac/Sources/ClarityLiveCoach/)
    - call.start / call.end: CoachModel+Call.swift startCall / endCall
    - speech.start: first words of a speaker after a pause (transcript arrival time) (CoachModel+Audio.swift handle)
    - transcript.partial / transcript.final: every Deepgram result. data.audio_start / audio_end are the
      times INSIDE the audio stream (Deepgram's clock, seconds since that stream opened), separate from t_ms
      (when the app received it). data.confidence, data.speech_final. (Deepgram.swift, CoachModel+Audio.swift)
    - turn.end: Deepgram said the speaker finished (speech_final or UtteranceEnd)
    - intent: what the code detected in the prospect's words and why (voicemail, screener, phone tree,
      opt out, bad number, objection match) (CoachModel+Audio.swift, LiveCoach.swift, Screener.swift)
    - script.match: approved-answer lookup: searched (row count), matched (row ID, phrase) or none
      (CoachCore ScriptAnswers, CoachModel+Lines.swift instantAnswer)
    - claude.request: model, settings, the exact system prompt size and hash, the exact user message
      (all context Claude got), early (started before they finished) (CoachModel+Lines.swift ask)
    - claude.first_token / claude.done (full raw output, ms) / claude.error / claude.cancelled
    - check.fail / check.fixed / check.trimmed: the code check on each line (Guardrail.swift, fixLine)
    - memory.update: the call summary Haiku keeps (new version, the text, which turns it covers)
    - suggestion.shown / suggestion.queued / suggestion.discarded / suggestion.promoted: what the rep saw,
      with the reason (CoachMachine.canReplace in CoachCore)
    - delivery: the rep said the line's meaning (confidence 0..1, what they said) (CoachCore Delivery)
    - resolution: the prospect answered after delivery
    - state: screen state change (Listening, Ready, Reading, Delivering, Interrupted, Resolved, Outdated, Idle)
    - manual: Hold, Release, Next, Different line
    - question.asked / question.answered / question.interrupted / question.abandoned: tracked in code (CoachCore
      QuestionTracker) from finished turns; the open/answered list is sent to Claude as facts (see user_message)
    - early.used / early.wasted: whether a draft started before they finished was the one used (proves generating ahead)
    - context.system: the full static instructions + script Claude had for this call (once per call)
    - log: every plain activity-log line during the call, for context

    ## Latency to compute
    speech end (turn.end) -> claude.request -> claude.first_token -> claude.done -> suggestion.shown;
    turn.end -> suggestion.shown is what the rep feels. transcript audio_end vs t_ms shows transcription delay.

    ## Not captured
    Claude's hidden reasoning (thinking is off for live lines). Call audio (only saved with the separate,
    consented voicemail samples and audio debug features).
    """
}
