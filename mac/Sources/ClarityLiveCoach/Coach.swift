import AVFoundation
import Foundation

// MARK: - What Claude sends back

struct Suggestion: Equatable {
    var say = ""
    var cue = ""
    var stage = ""
    var skip = false
    /// True once the SAY line is fully written (a line break came after it, or the answer ended).
    var sayComplete = false

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
            else if !s.say.isEmpty { s.sayComplete = true } // anything after SAY means SAY is done
            else if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("SKIP") { s.skip = true }
        }
        return s
    }
}

// MARK: - Prompt

enum CoachPrompt {
    static let stages = ["Opener", "Screener", "Gatekeeper", "Voicemail", "Discovery", "Objection", "Closing", "Goal reached", "Exit"]

    /// Stays byte-for-byte the same for a campaign, so Claude can cache it.
    static func system(for campaign: Campaign) -> String {
        """
        You are a world-class cold calling coach sitting next to a sales rep during a live phone call.
        Only the rep sees what you write. The prospect never hears it. You never speak to the prospect.
        The rep makes about 100 dials a day and can get overwhelmed. Make the next sentence obvious so they can stay calm and present.

        The transcript is labeled Rep and Prospect. It is live speech-to-text, so expect small errors.
        Speech-to-text often hears "Claude" as "cloud" or "clod". Read words in context.

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
        If an automated call screener answers (for example "say your name and why you're calling"), the rep says only:
        "This is [rep's first name] calling for [prospect's first name]." Then waits. Stage: Screener.
        11. If talk is flowing well or the rep is mid-thought, answer SKIP.

        Cold call method (adapt it to the campaign):
        - Opener: honest that it's a cold call, ask for a few seconds. Calm and slow beats slick.
        - Reason for the call: lead with a problem their peers have, not the product. Then ask if it's true for them.
        - Discovery: one question at a time. Follow up on their answer before moving on. Get the cost of the problem in their words: time, money, risk.
        - Keep them talking: repeat their last few words as a question, or name what they seem to feel ("Sounds like that rollout was frustrating").
        - Early objections are usually reflexes, not decisions. Lower the pressure and ask one question. If they repeat it firmly, respect it.
        - Ask for the objective as soon as there is real interest. Don't over-discover. Make it easy: specific, short, low commitment.
        - Use their first name at most once or twice. Silence is fine; don't fill it.
        - Never suggest "Did I catch you at a bad time?" It tests as the worst opener.
        - Never pitch features on a cold call. Earn the next step.

        Selling AI and automation (when the campaign is about AI):
        Buyers are skeptical and busy. Talk about outcomes in their words, like hours back, cleaner data and more selling time, not about AI itself.
        - "We already use ChatGPT or Copilot": good start. Ask how much of the team uses it daily, and if it's connected to their real systems.
        - "Security, legal or IT won't allow it": very fair. Ask what they'd need to see to be comfortable.
        - "We tried AI and it didn't stick": common. Ask what got in the way. Adoption usually fails on process and habits, not tech.
        - "AI is hype": agree there's a lot of noise. Ask about one boring manual task they'd love to be gone.
        - "We're building it in-house": ask if they're building tools or driving adoption, and what's slower than hoped.
        - "Not a priority": ask what is a priority this quarter. Connect only if there's a real link.
        - "Will it replace my people?": no. It gives them time back for the work they were hired to do.
        Never claim features, security certifications, prices or results the campaign doesn't state.

        Answer in exactly this format and nothing else:
        SAY: <the line the rep should say next>
        CUE: <why, or how to say it, under 10 words>
        STAGE: <one of: \(stages.joined(separator: ", "))>

        Or, when no help is needed:
        SKIP

        \(campaign.promptText)
        """
    }

    static func opener(calling: String?, style: Opener?) -> String {
        guard let style else {
            return "\(about(calling))The call has not connected yet. Give the opener the rep should say when they pick up."
        }
        return """
        \(about(calling))The call has not connected yet. Write the opener using this proven structure. \
        Keep its wording and shape; only fill in the brackets. [company] is the rep's company from the campaign. \
        If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
        Opener: \(style.template)
        Put the opener's name in the CUE: "\(style.name) opener".
        """
    }

    static func reply(turns: [Turn], latest: String, calling: String?, style: Opener?, openTimes: String?) -> String {
        let history = turns.suffix(30).map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        let opened = style.map { "The rep opened with the \"\($0.name)\" opener: \($0.template)\nGood follow-up for it: \($0.followUp)\n\n" } ?? ""
        let booking = openTimes.map {
            """
            Real free time for the meeting, from the calendar the rep books on (the meeting host's Google Calendar):
            \($0)
            When asking for the meeting, offer two specific times from these windows, say the time zone, and use these instead of any example times in the campaign. \
            If the prospect suggests a time, check it against the windows. If it isn't free, offer the closest free time. Never offer a time outside these windows.


            """
        } ?? ""
        return """
        \(about(calling))\(opened)\(booking)Call so far, oldest first:
        \(history)

        The prospect just said: "\(latest)"

        What should the rep say next?
        """
    }

    /// The Salesforce record the rep had open, from the Chrome tab title. Real data, not a guess.
    private static func about(_ calling: String?) -> String {
        var lines: [String] = []
        if let rep = UserDefaults.standard.string(forKey: "repName")?.trimmed, !rep.isEmpty {
            lines.append("The rep's first name is \(rep).")
        }
        if let calling {
            lines.append("Salesforce record open in the rep's browser: \(calling). Use the first name if it's a person. Assume nothing else about them.")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
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

/// Lowercase words only, so "Sure, go ahead." matches "sure go ahead".
func normalized(_ text: String) -> String {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

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
    enum Kind { case opener, reply, screener }

    @Published private(set) var status: Status = .ready
    @Published private(set) var suggestion = Suggestion()
    @Published private(set) var kind: Kind = .opener
    @Published private(set) var latestProspect = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var interim: [Speaker: String] = [:]
    @Published private(set) var latency: Double?
    @Published private(set) var problem: String?
    @Published private(set) var thinking = false
    /// Who the rep is calling, from the Salesforce tab title (e.g. Lead "Jane Doe").
    @Published private(set) var calling: String?
    private var tabTicks = 0

    /// Proven openers, rotated call by call, with your own scoreboard.
    let openers = OpenerBook()
    private var callOpener: Opener?   // the opener used on this call
    private var goalHit = false
    private var sawVoicemail = false
    private var stagesSeen: Set<String> = []
    private var screenerActive = false       // a screener is talking; wait for the real person
    private var openerBeforeScreener: Suggestion?
    private var firstProspectAt: Date?
    private var lastWordsAt: Date?

    /// Scores every answered call and suggests script improvements over time.
    let lab = CallLab()
    /// Real free time from the rep's Google Calendar, for booking.
    let availability = Availability()

    private var openerStyle: Opener? { openers.rotate ? openers.current : nil }

    @Published private(set) var campaign = Campaign.clarityDiscovery
    private var system = CoachPrompt.system(for: .clarityDiscovery)

    /// Switches (or refreshes) the campaign. Takes effect right away between calls.
    /// Refreshes the opener after a setting changes (rotation, your name).
    func refreshOpener() {
        if status == .ready { prepareOpener() }
    }

    func use(_ next: Campaign) {
        guard next != campaign else { return }
        campaign = next
        system = CoachPrompt.system(for: next)
        if status == .ready { prepareOpener() }
    }

    private let capture = CaptureEngine()
    private let streams = StreamBox()
    private var timer: Timer?
    private var startedByHand = false
    private var quietTicks = 0
    private var reconnects = 0
    private var useKeyterms = true // turned off if Deepgram ever rejects them

    private var uncoached = ""          // prospect words not yet answered
    private var seq = 0                 // newest request id; older ones are stale
    private var coachTask: Task<Void, Never>?
    private var shownID = 0
    private var shownAt = Date.distantPast
    private var pending: (id: Int, suggestion: Suggestion)?
    private var holdTask: Task<Void, Never>?
    private var timedID = 0

    // Starting early: when the prospect's sentence sounds finished, Claude starts writing before
    // the transcriber confirms they stopped. The answer is held until they really stop.
    private var specBasis: String?                 // the words the early answer was started on
    private var specHeld: (s: Suggestion, id: Int)?
    private var specTimer: Task<Void, Never>?
    private var confirmedAt: Date?

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
        // Between calls, notice which record is open so the opener uses their name.
        if status == .ready, !onCall {
            tabTicks += 1
            if tabTicks % 2 == 0 {
                let record = SalesforceTab.currentRecord()
                if record != calling {
                    calling = record
                    prepareOpener()
                }
            }
        }
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
        availability.refresh() // fresh free times for this call
        callOpener = kind == .opener ? openerStyle : nil
        goalHit = false
        sawVoicemail = false
        stagesSeen = []
        screenerActive = false
        openerBeforeScreener = nil
        firstProspectAt = nil
        lastWordsAt = nil
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        scoreOpener()
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
        calling = SalesforceTab.currentRecord()
        prepareOpener()
    }

    /// Scores the call if a real person answered (not voicemail): credits the opener,
    /// then saves it to the Script Lab.
    private func scoreOpener() {
        defer { callOpener = nil }
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        // Skip voicemails, no-answers, and calls where only a screener ever talked.
        guard status != .ready, !sawVoicemail, !screenerActive, prospectTurns > 0, let start = firstProspectAt else { return }
        let talk = max(0, (lastWordsAt ?? start).timeIntervalSince(start))
        let score = CallScore.compute(talkSeconds: talk, stages: stagesSeen, goal: goalHit)
        let usedOpener = callOpener.flatMap { $0 == openers.current ? $0 : nil }
        if usedOpener != nil {
            openers.record(score: score, kept: prospectTurns >= 3, goal: goalHit)
        }
        let record = CallRecord(
            campaignID: campaign.id, campaignVersion: campaign.version, openerID: usedOpener?.id,
            talkSeconds: talk, prospectTurns: prospectTurns, stages: Array(stagesSeen).sorted(),
            goal: goalHit, score: score
        )
        let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        lab.add(record, campaign: campaign, transcript: transcript)
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
        DeepgramStream(apiKey: key, keyterms: useKeyterms ? DeepgramStream.defaultKeyterms : []) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: speaker) }
        }
    }

    private func handle(_ event: DeepgramStream.Event, from speaker: Speaker) {
        guard status == .live else { return }
        switch event {
        case .transcript(let text, let isFinal, let speechFinal):
            if speaker == .prospect, !screenerActive, stagesSeen.contains("Screener") == false, Screener.detects(text) {
                showScreenerLine()
            }
            if isFinal {
                reconnects = 0
                interim[speaker] = nil
                if !text.isEmpty { addFinal(text, from: speaker) }
                if speechFinal && speaker == .prospect { prospectFinished() }
            } else {
                interim[speaker] = text
                if speaker == .prospect { scheduleEarlyStart() }
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
            useKeyterms = false // reconnect with the plainest settings
            streams.replace(speaker, with: openStream(speaker, key: key))
        }
    }

    private func addFinal(_ text: String, from speaker: Speaker) {
        lastWordsAt = Date()
        if speaker == .prospect, firstProspectAt == nil { firstProspectAt = Date() }
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1].text += " " + text
        } else {
            turns.append(Turn(speaker: speaker, text: text))
        }
        if speaker == .prospect {
            uncoached += (uncoached.isEmpty ? "" : " ") + text
        }
    }

    /// Instant line for a call screener. No Claude call, no waiting.
    private func showScreenerLine() {
        screenerActive = true
        coachTask?.cancel()
        holdTask?.cancel()
        pending = nil
        if kind == .opener { openerBeforeScreener = suggestion }
        seq += 1
        show(Suggestion(say: Screener.line(calling: calling),
                        cue: "Call screener. Say it slowly and clearly, then wait.",
                        stage: "Screener"),
             id: seq, kind: .screener)
    }

    /// If the prospect's words end like a finished sentence and hold still for a moment,
    /// start Claude now instead of waiting for the end-of-speech signal.
    private func scheduleEarlyStart() {
        specTimer?.cancel()
        guard status == .live, !screenerActive else { return }
        let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
        guard let last = text.last, ".?!".contains(last), isMeaningful(text) else { return }
        specTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled,
                  (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
                  normalized(text) != self.specBasis else { return }
            self.ask(.reply, user: CoachPrompt.reply(
                turns: self.turns, latest: text, calling: self.calling, style: self.callOpener,
                openTimes: self.availability.openTimesText()
            ), early: text)
        }
    }

    /// The prospect stopped talking. Decide if the rep needs a new line.
    private func prospectFinished() {
        specTimer?.cancel()
        let said = uncoached.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        // Started early on exactly these words? Then the answer is already on its way.
        if let basis = specBasis {
            specBasis = nil
            if basis == normalized(said) {
                uncoached = ""
                latestProspect = said
                confirmedAt = Date()
                if let held = specHeld {
                    specHeld = nil
                    offer(held.s, id: held.id, kind: .reply, askedAt: confirmedAt!)
                }
                return
            }
        }
        if screenerActive {
            uncoached = ""
            if Screener.detects(said) { return } // still the screener talking
            // A real person picked up after the screener: back to the opener.
            screenerActive = false
            latestProspect = said
            if let opener = openerBeforeScreener {
                seq += 1
                show(opener, id: seq, kind: .opener)
                return
            }
        }
        uncoached = ""
        latestProspect = said
        // A plain "Hello?" is already answered by the opener on screen.
        let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
        // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
        let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else { return }
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: said, calling: calling, style: callOpener,
            openTimes: availability.openTimesText()
        ))
    }

    // MARK: Claude

    private func prepareOpener() {
        ask(.opener, user: CoachPrompt.opener(calling: calling, style: openerStyle))
    }

    private func ask(_ kind: Kind, user: String, early: String? = nil) {
        guard let key = Keychain.read(.anthropic) else {
            problem = "Add your Anthropic key in Settings."
            return
        }
        coachTask?.cancel() // a newer statement makes the old answer stale
        seq += 1
        let id = seq
        let askedAt = Date()
        specBasis = early.map(normalized)
        specHeld = nil
        confirmedAt = nil
        let client = CoachSpeed.current.client(apiKey: key)
        let system = self.system
        thinking = true

        coachTask = Task { [weak self] in
            do {
                var finalText = ""
                try await client.stream(system: system, user: user) { text in
                    finalText = text
                    let s = Suggestion.parse(text)
                    Task { @MainActor in self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
                }
                var last = Suggestion.parse(finalText)
                last.sayComplete = true
                self?.offer(last, id: id, kind: kind, askedAt: askedAt)
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
        // Easier to read live: show the line once it's whole, not word by word (setting).
        let wholeLine = UserDefaults.standard.object(forKey: "wholeLine") as? Bool ?? true
        if wholeLine && !s.sayComplete { return }
        if specBasis != nil {
            specHeld = (s, id) // started early: wait until they really stop talking
            return
        }
        if kind == .reply, timedID != id {
            timedID = id // time from "they stopped talking" to the first words of the answer
            latency = max(0, Date().timeIntervalSince(confirmedAt ?? askedAt))
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
        if status != .ready, !s.stage.isEmpty { stagesSeen.insert(s.stage) }
        if s.stage == "Goal reached" { goalHit = true }
        if s.stage == "Voicemail" { sawVoicemail = true }
    }
}
