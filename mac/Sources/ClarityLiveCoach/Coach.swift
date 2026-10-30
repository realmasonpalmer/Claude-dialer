import AVFoundation
import Foundation

// MARK: - What Claude sends back

struct Suggestion: Equatable {
    var say = ""
    var cue = ""
    var stage = ""
    var skip = false

    /// Claude answers in a tiny line format so words can show while they stream:
    ///   SAY: ...
    ///   CUE: ...
    ///   STAGE: ...
    /// or SKIP when the rep needs no help.
    static func parse(_ text: String) -> Suggestion {
        var s = Suggestion()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SAY:") { s.say = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("SKIP") { s.skip = true }
        }
        return s
    }
}

// MARK: - Prompt

enum CoachPrompt {
    static let stages = ["Opener", "Gatekeeper", "Voicemail", "Discovery", "Objection", "Closing", "Goal reached", "Exit"]

    /// Stays byte-for-byte the same for a campaign, so Claude can cache it.
    static func system(for campaign: Campaign) -> String {
        """
        You are a world-class cold calling coach sitting next to a sales rep during a live phone call.
        Only the rep sees what you write. The prospect never hears it. You never speak to the prospect.
        The rep makes about 100 dials a day and can get overwhelmed. Make the next sentence obvious so they can stay calm and present.

        The transcript is labeled Rep and Prospect. It is live speech-to-text, so expect small errors.

        How to coach:
        1. One line at a time, 10 to 20 words. Easy to say out loud on the first read.
        2. Sound like a confident, friendly human. Plain words, contractions, no jargon, no hype.
        3. Prefer one short question over a pitch.
        4. Respond to what the prospect actually just said. Never contradict a need they stated.
        5. Objections: acknowledge in a few words, then ask a curious question. Never argue.
        6. Use the campaign as the strategy, not a script to read word for word. Adapt to the prospect.
        7. Never ask something they already answered. Never invent facts about them or their company.
        8. Move toward the campaign objective. Once it is reached, help the rep confirm details and wrap up. Stop selling.
        9. After two clear no's, a request not to be called, or no fit: help the rep exit politely.
        10. If it is voicemail or a gatekeeper, use the campaign's guidance for that.
        11. If talk is flowing well or the rep is mid-thought, answer SKIP.

        Answer in exactly this format and nothing else:
        SAY: <the line the rep should say next>
        CUE: <why, or how to say it, under 10 words>
        STAGE: <one of: \(stages.joined(separator: ", "))>

        Or, when no help is needed:
        SKIP

        # Campaign: \(campaign.name)
        Objective: \(campaign.objective)

        \(campaign.playbook)
        """
    }

    static func opener() -> String {
        "The call has not connected yet. Give the opener the rep should say when they pick up."
    }

    static func reply(turns: [Turn], latest: String) -> String {
        let history = turns.suffix(30).map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        return """
        Call so far, oldest first:
        \(history)

        The prospect just said: "\(latest)"

        What should the rep say next?
        """
    }
}

// MARK: - Call state

enum Speaker { case rep, prospect }

struct Turn: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    var text: String
}

/// Short noises that never need a new line on their own.
private let filler: Set<String> = [
    "yeah", "yep", "yes", "ok", "okay", "uh", "um", "uh-huh", "mhm", "mm-hmm", "hmm",
    "right", "sure", "got", "it", "cool", "nice", "great", "hello", "hi",
]

func isMeaningful(_ text: String) -> Bool {
    text.lowercased()
        .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
        .contains { !$0.isEmpty && !filler.contains($0) }
}

/// Holds the two transcription streams so audio threads can reach them safely.
final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rep: DeepgramStream?
    private var prospect: DeepgramStream?

    func set(rep: DeepgramStream?, prospect: DeepgramStream?) {
        lock.withLockValue { self.rep = rep; self.prospect = prospect }
    }

    func replace(_ speaker: Speaker, with stream: DeepgramStream?) {
        let old = lock.withLockValue { () -> DeepgramStream? in
            defer { if speaker == .rep { rep = stream } else { prospect = stream } }
            return speaker == .rep ? rep : prospect
        }
        old?.close()
    }

    func send(_ data: Data, isRep: Bool) {
        let stream = lock.withLockValue { isRep ? rep : prospect }
        stream?.send(data)
    }

    func closeAll() {
        let (r, p) = lock.withLockValue { (rep, prospect) }
        r?.close()
        p?.close()
        set(rep: nil, prospect: nil)
    }
}

// MARK: - The coach

@MainActor
final class CoachModel: ObservableObject {
    enum Status { case ready, live, paused }
    enum Kind { case opener, reply }

    @Published private(set) var status: Status = .ready
    @Published private(set) var suggestion = Suggestion()
    @Published private(set) var kind: Kind = .opener
    @Published private(set) var latestProspect = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var interim: [Speaker: String] = [:]
    @Published private(set) var latency: Double?
    @Published private(set) var problem: String?
    @Published private(set) var thinking = false

    let campaign = Campaign.clarityDiscovery
    private lazy var system = CoachPrompt.system(for: campaign)

    private let capture = CaptureEngine()
    private let streams = StreamBox()
    private var timer: Timer?
    private var startedByHand = false
    private var quietTicks = 0
    private var reconnects = 0

    private var uncoached = ""          // prospect words not yet answered
    private var seq = 0                 // newest request id; older ones are stale
    private var coachTask: Task<Void, Never>?
    private var shownID = 0
    private var shownAt = Date.distantPast
    private var pending: (id: Int, suggestion: Suggestion)?
    private var holdTask: Task<Void, Never>?
    private var timedID = 0

    /// A new line never replaces one the rep has had less than this long to read.
    private let hold: TimeInterval = 2.5

    private var active = false

    /// Only the visible coach screen reacts to calls (not while the audio check runs).
    func activate(_ on: Bool) {
        active = on
        if on { onAppear() } else if status != .ready { nextCall() }
    }

    func onAppear() {
        if suggestion.say.isEmpty, !thinking { prepareOpener() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Call lifecycle

    private func tick() {
        guard active else { return }
        let onCall = AudioProcess.chromeOnCall(in: AudioProcess.others())
        switch status {
        case .ready where onCall:
            startCall()
        case .live where !startedByHand:
            quietTicks = onCall ? 0 : quietTicks + 1
            if quietTicks >= 6 { nextCall() } // call over for 3 seconds
        default:
            break
        }
    }

    func startByHand() {
        startedByHand = true
        startCall()
    }

    private func startCall() {
        problem = nil
        guard startAudio() else { return }
        status = .live
        quietTicks = 0
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        stopAudio()
        coachTask?.cancel()
        holdTask?.cancel()
        startedByHand = false
        turns = []
        interim = [:]
        uncoached = ""
        latestProspect = ""
        latency = nil
        status = .ready
        prepareOpener()
    }

    func togglePause() {
        if status == .paused {
            if startAudio() { status = .live }
        } else if status == .live {
            stopAudio()
            coachTask?.cancel()
            status = .paused
        }
    }

    // MARK: Audio and transcription

    private func startAudio() -> Bool {
        guard let deepgramKey = Keychain.read(.deepgram) else {
            problem = "Add your Deepgram key in Settings."
            return false
        }
        let chrome = AudioProcess.others().filter(\.isChrome).map(\.id)
        guard !chrome.isEmpty else {
            problem = "Chrome isn't playing any sound. Start the Aircall call first."
            return false
        }
        streams.set(rep: openStream(.rep, key: deepgramKey), prospect: openStream(.prospect, key: deepgramKey))
        do {
            let streams = self.streams
            try capture.start(processes: chrome) { isRep, speech in
                guard let samples = speech.int16ChannelData?[0] else { return }
                streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: isRep)
            }
            return true
        } catch {
            streams.closeAll()
            problem = error.localizedDescription
            return false
        }
    }

    private func stopAudio() {
        capture.stop()
        streams.closeAll()
    }

    private func openStream(_ speaker: Speaker, key: String) -> DeepgramStream {
        DeepgramStream(apiKey: key) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: speaker) }
        }
    }

    private func handle(_ event: DeepgramStream.Event, from speaker: Speaker) {
        guard status == .live else { return }
        switch event {
        case .transcript(let text, let isFinal, let speechFinal):
            if isFinal {
                reconnects = 0
                interim[speaker] = nil
                if !text.isEmpty { addFinal(text, from: speaker) }
                if speechFinal && speaker == .prospect { prospectFinished() }
            } else {
                interim[speaker] = text
            }
        case .utteranceEnd:
            if speaker == .prospect { prospectFinished() }
        case .failed(let message):
            // Keep the call and the last tip; just reconnect this side.
            guard reconnects < 3, let key = Keychain.read(.deepgram) else {
                problem = "Transcription stopped: \(message)"
                return
            }
            reconnects += 1
            streams.replace(speaker, with: openStream(speaker, key: key))
        }
    }

    private func addFinal(_ text: String, from speaker: Speaker) {
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1].text += " " + text
        } else {
            turns.append(Turn(speaker: speaker, text: text))
        }
        if speaker == .prospect {
            uncoached += (uncoached.isEmpty ? "" : " ") + text
        }
    }

    /// The prospect stopped talking. Decide if the rep needs a new line.
    private func prospectFinished() {
        let said = uncoached.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        uncoached = ""
        latestProspect = said
        // A plain "Hello?" is already answered by the opener on screen.
        let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
        guard !onlyGreeting, isMeaningful(said) || turns.count <= 2 else { return }
        ask(.reply, user: CoachPrompt.reply(turns: turns, latest: said))
    }

    // MARK: Claude

    private func prepareOpener() {
        ask(.opener, user: CoachPrompt.opener())
    }

    private func ask(_ kind: Kind, user: String) {
        guard let key = Keychain.read(.anthropic) else {
            problem = "Add your Anthropic key in Settings."
            return
        }
        coachTask?.cancel() // a newer statement makes the old answer stale
        seq += 1
        let id = seq
        let askedAt = Date()
        let client = ClaudeClient(apiKey: key)
        let system = self.system
        thinking = true

        coachTask = Task { [weak self] in
            do {
                try await client.stream(system: system, user: user) { text in
                    let s = Suggestion.parse(text)
                    Task { @MainActor in self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                // Keep the last good line on screen; just flag it.
                self?.problem = "Coach hiccup: \(error.localizedDescription)"
            }
            if self?.seq == id { self?.thinking = false }
        }
    }

    /// Shows a suggestion, but never swaps a fresh line out from under the rep.
    private func offer(_ s: Suggestion, id: Int, kind: Kind, askedAt: Date) {
        guard id == seq, !s.skip, !s.say.isEmpty else { return }
        if kind == .reply, timedID != id {
            timedID = id // time from "they stopped talking" to the first words of the answer
            latency = Date().timeIntervalSince(askedAt)
        }
        if id == shownID {
            suggestion = s // same answer, still streaming in
            return
        }
        let waited = Date().timeIntervalSince(shownAt)
        if kind == .opener || shownID == 0 || waited >= hold {
            show(s, id: id, kind: kind)
        } else {
            pending = (id, s)
            holdTask?.cancel()
            let delay = hold - waited
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, let next = self.pending, next.id == self.seq else { return }
                self.show(next.suggestion, id: next.id, kind: kind)
            }
        }
    }

    private func show(_ s: Suggestion, id: Int, kind: Kind) {
        pending = nil
        shownID = id
        shownAt = Date()
        suggestion = s
        self.kind = kind
        problem = nil
    }
}
