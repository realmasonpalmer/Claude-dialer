import AppKit
import AVFoundation
import Combine
import Foundation

// MARK: - What Claude sends back

struct Suggestion: Equatable {
    var say = ""
    var cue = ""
    var stage = ""
    var skip = false
    /// True once the SAY line is fully written (a line break came after it, or the answer ended).
    var sayComplete = false
    /// Codes of the meeting times this line offers or confirms, e.g. ["T3", "T5"].
    var offered: [String] = []
    /// Voicemail follow-ups: a text to send and a LinkedIn connection note.
    var textMessage = ""
    var linkedin = ""
    var linkedinMessage = ""

    /// Claude answers in a tiny line format so words can show while they stream:
    ///   SAY: ...
    ///   CUE: ...
    ///   STAGE: ...
    ///   OFFERED: T3, T5   (only when the line offers meeting times)
    /// or SKIP when the rep needs no help.
    static func parse(_ text: String) -> Suggestion {
        var s = Suggestion()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SAY:") {
                s.say = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !s.say.isEmpty { s.sayComplete = true } // any line after SAY means SAY is done
            if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("SKIP") { s.skip = true }
            else if trimmed.hasPrefix("TEXT:") { s.textMessage = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("LINKEDIN MESSAGE:") { s.linkedinMessage = String(trimmed.dropFirst(17)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("LINKEDIN:") { s.linkedin = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("OFFERED:") {
                s.offered = trimmed.dropFirst(8).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            }
        }
        return s
    }
}

// MARK: - Prompt

enum CoachPrompt {
    static let stages = ["Opener", "Screener", "Gatekeeper", "Voicemail", "Discovery", "Value", "Objection", "Closing", "Goal reached", "Exit"]

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
        - Value (STAGE: Value): one sentence tying the problem they named to what the campaign offers, then a question.
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

    static func opener(calling: String?, details: String?, style: Opener?) -> String {
        guard let style else {
            return "\(about(calling, details))The call has not connected yet. Give the opener the rep should say when they pick up."
        }
        return """
        \(about(calling, details))The call has not connected yet. Write the opener using this proven structure. \
        Keep its wording and shape; only fill in the brackets. [company] is the rep's company from the campaign. \
        If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
        Opener: \(style.template)
        Put the opener's name in the CUE: "\(style.name) opener".
        """
    }

    static func reply(turns: [Turn], latest: String, calling: String?, details: String?, style: Opener?, openTimes: String?) -> String {
        let history = turns.suffix(30).map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        let opened = style.map { "The rep opened with the \"\($0.name)\" opener: \($0.template)\nGood follow-up for it: \($0.followUp)\n\n" } ?? ""
        let booking = openTimes.map { "\($0)\n\n" } ?? ""
        return """
        \(about(calling, details))\(opened)\(booking)Call so far, oldest first:
        \(history)

        The prospect just said: "\(latest)"

        What should the rep say next?
        """
    }

    /// Written before the call, so it's ready the instant a voicemail greeting starts.
    static func voicemail(calling: String?, details: String?) -> String {
        """
        \(about(calling, details))If this call goes to voicemail, what should the rep say after the beep?
        Under 20 seconds, about 40 words. In this order: their first name; the rep's name and company;
        one reason tied to something specific about them, their role or their company (from the Salesforce facts,
        or a common pain for their title if there are none); then "I'll send you a quick text so you have my number."
        No pitch, no hype, no email.
        CUE: one short delivery tip. STAGE: Voicemail.
        Then add three more lines:
        TEXT: <the text message to send right after. Under 25 words. Rep's name and company, the same one reason,
        and one easy yes/no question.>
        LINKEDIN: <a LinkedIn connection request note. Under 200 characters. Says the rep just tried calling,
        gives the same specific reason, no pitch, no links, no emojis.>
        LINKEDIN MESSAGE: <a LinkedIn direct message, for when they're already connected. Under 400 characters.
        Says the rep just tried calling, gives the same specific reason, one easy question. No links, no emojis.>
        """
    }

    /// The Salesforce record the rep had open: the tab title and, if allowed, the page's text.
    private static func about(_ calling: String?, _ details: String? = nil) -> String {
        var lines: [String] = []
        if let rep = UserDefaults.standard.string(forKey: "repName")?.trimmed, !rep.isEmpty {
            lines.append("The rep's first name is \(rep).")
        }
        if let calling {
            lines.append("Salesforce record open in the rep's browser: \(calling). Use the first name if it's a person.")
        }
        if let details {
            lines.append("Text from their Salesforce page. It includes menus and clutter; use only facts about this person and their company, and never guess:\n\(details)")
        } else if calling != nil {
            lines.append("Assume nothing else about them.")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
    }
}

// MARK: - Voicemail follow-ups

struct FollowUp: Equatable {
    /// Which record this is for, so a 2nd-try voicemail keeps what the 1st try already sent.
    var key: String?
    var prospect: String?
    var text = ""
    var linkedin = ""
    var textDone = false
    var linkedinDone = false
    /// Their phone, from the Salesforce page; editable on the card.
    var phone = ""
    /// Their LinkedIn profile, from the Salesforce record's LinkedIn field.
    var linkedinURL: URL?
    /// "Sending...", "Sent", or an error, for the text row.
    var textStatus: String?
    /// A LinkedIn direct message, for people who are already connected.
    var linkedinMessage = ""
    var linkedinMessageDone = false

    /// Text sent, plus a LinkedIn note or a LinkedIn message (one or the other, not both).
    var allDone: Bool { textDone && (linkedinDone || linkedinMessageDone) }
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
    enum Kind { case opener, reply, screener, voicemail }

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
    /// Text from the open Salesforce page, when Chrome allows it.
    @Published private(set) var recordDetails: String?
    private var tabTicks = 0
    private var voicemailScript: Suggestion?   // written ahead of time for this prospect
    private var voicemailTask: Task<Void, Never>?
    private var voicemailActive = false
    private var mailboxFullShown = false

    // MARK: Where the call is

    /// The four steps shown at the top: Opener -> Discovery -> Value -> Close.
    static let journey = ["Opener", "Discovery", "Value", "Close"]
    @Published private(set) var journeyStep = 0
    var nextStepName: String? { journeyStep + 1 < Self.journey.count ? Self.journey[journeyStep + 1] : nil }

    /// Lines shown on this call, so Back can show the previous one.
    private var history: [(s: Suggestion, kind: Kind)] = []
    @Published private(set) var historyIndex: Int?   // nil = showing the newest line
    var canGoBack: Bool { (historyIndex ?? history.count - 1) > 0 }

    /// True while the prospect is talking (words are coming in from their side).
    var prospectSpeaking: Bool { !(interim[.prospect] ?? "").isEmpty }

    private func trackJourney(_ stage: String) {
        let step: Int?
        switch stage {
        case "Opener", "Screener", "Gatekeeper", "Voicemail": step = 0
        case "Discovery": step = 1
        case "Value": step = 2
        case "Closing", "Goal reached": step = 3
        default: step = nil // Objection, Exit: stay where we are
        }
        if let step, step > journeyStep { journeyStep = step }
    }

    /// Shows the line before the one on screen.
    func back() {
        let current = historyIndex ?? history.count - 1
        guard current > 0 else { return }
        historyIndex = current - 1
        suggestion = history[current - 1].s
        kind = history[current - 1].kind
    }

    /// Back to the newest line after looking back.
    func showLatest() {
        guard let latest = history.last else { return }
        historyIndex = nil
        suggestion = latest.s
        kind = latest.kind
    }

    /// Asks for the line that moves the call to the next step.
    func advanceStep() {
        guard let next = nextStepName else { newLine(); return }
        newLine(extra: "Move the call forward to the next step: \(next). Write the line that starts it now.")
    }

    /// The rep's Salesforce list, for the Next button.
    let callList = CallList()
    private var detailsTask: Task<Void, Never>?
    private var listWatcher: AnyCancellable?
    private var leadsWatcher: AnyCancellable?
    private var leadDetailsWatcher: AnyCancellable?

    // MARK: Lead list (Salesforce) and dialing (Aircall)

    /// The call list from a Salesforce list view. When active, Chrome isn't needed at all.
    let leads = LeadQueue()
    private var appliedLeadID: String?
    private var pendingDialSince: Date?
    @Published private(set) var dialing = false
    @Published var dialError: String?

    // MARK: Status card (Contact: Relationship Status. Lead: Lead Status.)

    /// The Contact or Lead on screen.
    @Published private(set) var statusRecordID: String?
    /// What Salesforce says right now (nil = blank or not loaded yet).
    @Published private(set) var recordStatus: String?
    @Published private(set) var savingStatus = false
    @Published var statusMessage: String?

    /// "Contact" or "Lead" for the record on screen.
    var statusObject: String? { statusRecordID.flatMap(Salesforce.objectFor) }

    /// Notices which Contact or Lead is on screen and loads its status.
    func refreshRelationship() {
        let id: String? = leads.isActive ? leads.details?.id : SalesforceChrome.url().flatMap(CallList.recordID)
        let usable = id.flatMap { Salesforce.objectFor(id: $0) == nil ? nil : $0 }
        guard usable != statusRecordID else { return }
        statusRecordID = usable
        recordStatus = nil
        statusMessage = nil
        guard let usable else { return }
        if RemovedList.contains(usable) || DialHistory.isMaxed(usable) { skipRemoved(usable); return }
        guard Salesforce.isConnected else { return }
        Task { [weak self] in
            let value = try? await Salesforce.status(of: usable)
            guard let self, self.statusRecordID == usable else { return }
            self.recordStatus = value ?? nil
            if let value, Salesforce.removedStatuses.contains(value) {
                RemovedList.add(usable)
                self.skipRemoved(usable)
            }
        }
    }

    /// Someone already marked Not Quality Prospect, Negative or Unqualified came up between calls:
    /// move on to the next person (without calling). Only for people on the call list, so opening
    /// a record by hand to look at it doesn't jump away.
    private func skipRemoved(_ id: String) {
        guard status == .ready, !dialing else { return }
        let onList = leads.isActive
            ? leads.current.map { String($0.id.prefix(15)) == String(id.prefix(15)) } ?? false
            : callList.records.contains { String($0.id.prefix(15)) == String(id.prefix(15)) }
        guard onList else { return }
        statusMessage = nil
        problem = "Skipped someone marked off your list."
        nextLead(dial: false)
    }

    /// The Save button: writes the status to Salesforce.
    /// "Not Quality Prospect", "Negative" and "Unqualified" also take them off the call list.
    func saveStatus(_ value: String) {
        guard let id = statusRecordID, !savingStatus else { return }
        guard Salesforce.isConnected else {
            statusMessage = "Sign in to Salesforce first: gear menu > Setup > Salesforce."
            return
        }
        savingStatus = true
        statusMessage = nil
        Task { [weak self] in
            do {
                try await Salesforce.setStatus(of: id, to: value)
                guard let self else { return }
                self.savingStatus = false
                guard self.statusRecordID == id else { return }
                self.recordStatus = value
                if Salesforce.removedStatuses.contains(value) {
                    RemovedList.add(id)
                    self.statusMessage = "Saved. Taken off your list."
                    // Between calls: move on to the next person right away (without calling yet).
                    if self.status == .ready { self.nextLead(dial: false) }
                } else {
                    RemovedList.remove(id)
                    self.statusMessage = "Saved."
                }
                self.callList.refreshUpNext()
            } catch {
                self?.savingStatus = false
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    /// Points the coach at the lead on screen: name, details, opener, voicemail.
    func applyLead() {
        guard let d = leads.details else { return }
        if d.id != currentAttemptKey { currentAttemptKey = nil; lastCallAnswered = true }
        appliedLeadID = d.id
        calling = "\(d.object) \"\(d.name)\""
        recordDetails = d.promptText
        prepareOpener()
        prepareVoicemail()
        refreshRelationship()
    }

    /// Calls the lead from the Aircall desktop app.
    func dial(_ number: String? = nil) {
        guard status == .ready, !dialing, let d = leads.details, !d.doNotCall,
              let phone = number ?? d.callNumber else { return }
        dialing = true
        dialError = nil
        Task { [weak self] in
            do {
                try await Aircall.startCall(to: phone)
                guard let self else { return }
                self.dialing = false
                self.leads.markCurrentCalled()
                self.pendingDialSince = Date()
            } catch {
                self?.dialing = false
                self?.dialError = error.localizedDescription
            }
        }
    }

    /// Ends the call (if any) and opens the next lead on the rep's list. The coach then
    /// picks up the new record and writes a fresh opener and voicemail for it.
    func previousLead() {
        cancelAutoNext()
        if leads.isActive {
            if status != .ready { endCall() }
            Task { await leads.back() }
            return
        }
        if status != .ready { nextCall() }
        if callList.openPrevious() {
            suggestion = Suggestion()
            calling = nil
            tabTicks = 1
        }
    }

    /// - Parameter dial: false = just show the next person, don't call yet.
    func nextLead(dial shouldDial: Bool = true) {
        cancelAutoNext()
        let dialNow = shouldDial && (UserDefaults.standard.object(forKey: "nextDials") as? Bool ?? true)
        if leads.isActive {
            if status != .ready { endCall() }
            Task { [weak self] in
                guard let self else { return }
                guard await self.leads.next() else { return }
                // Skip Do Not Call records and records with no mobile number (up to 20 in a row).
                var skipped = 0
                while self.leads.details.map({ $0.doNotCall || $0.callNumber == nil }) == true, skipped < 20,
                      await self.leads.next() { skipped += 1 }
                // "Next calls right away" (on by default): dial as soon as the lead is loaded.
                if dialNow, self.leads.details?.doNotCall == false {
                    self.applyLead()
                    self.dial()
                } else {
                    self.applyLead()
                }
            }
            return
        }
        if status != .ready { endCall() }
        if openNextInChrome(), dialNow {
            dialFromSalesforcePage(expecting: callList.lastOpenedID)
        }
    }

    /// Opens the next person in the Salesforce tab and points the coach at them right away.
    private func openNextInChrome() -> Bool {
        guard callList.openNext() else { return false }
        let upcoming = callList.records.first { $0.id == callList.lastOpenedID }?.name
        // Show their opener now, before the page loads and before the phone rings.
        let kind = callList.lastOpenedID.map { $0.hasPrefix("003") ? "Contact" : "Lead" } ?? "Lead"
        calling = upcoming.map { "\(kind) \"\($0)\"" }
        recordDetails = nil
        detailsTried = false
        personalOpenerFor = nil
        prepareOpener()
        detailsPending = true // read their page once it loads, for a more personal line
        tabTicks = 1  // read the page on the very next tick
        return true
    }

    // MARK: Moving on after a call: send the text, load the next person, count down, dial

    /// The "Auto-dial" switch next to Aircall phone.
    var autoDial: Bool {
        get { UserDefaults.standard.object(forKey: "nextDials") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nextDials"); objectWillChange.send() }
    }

    /// The text was sent (or skipped): open the next person, wait until their opener,
    /// voicemail and follow-ups are all for them, then count down 5 seconds and dial.
    /// With Auto-dial off, it only opens the next person.
    func startNextSequence() {
        cancelAutoNext()
        guard status == .ready else { return }
        followUp = nil // the last person's follow-ups are done
        if leads.isActive {
            if autoDial { startAutoNext() } else { nextLead(dial: false) }
            return
        }
        guard openNextInChrome() else { return }
        if autoDial { dialFromSalesforcePage(expecting: callList.lastOpenedID, countdown: 5) }
    }

    // MARK: Double dial

    /// Calls per lead today, and whether the last call reached a person.
    private var attempts: [String: Int] = [:]
    @Published private(set) var currentAttemptKey: String?
    @Published private(set) var lastCallAnswered = true
    var currentAttempts: Int { currentAttemptKey.flatMap { attempts[$0] } ?? 0 }

    /// After a first try nobody answered (or voicemail), offer to call right back.
    var shouldOfferRedial: Bool {
        status == .ready && currentAttemptKey != nil && !lastCallAnswered && currentAttempts < 2
            && !(currentAttemptKey.map(DialHistory.isMaxed) ?? false) // last try: no redial
    }

    /// Who the current lead is, for counting tries.
    private func recordKey() -> String? {
        if leads.isActive { return leads.details?.id }
        return SalesforceChrome.url().flatMap(CallList.recordID) ?? calling
    }

    /// Calls the same person again right away.
    func redial() {
        guard status == .ready, currentAttemptKey != nil else { return }
        cancelAutoNext()
        if leads.isActive {
            dial()
        } else if !dialing, !callFromPage() {
            problem = "No mobile number on this Salesforce page. Click Next."
        }
    }

    /// The Call button for the lead open in Salesforce.
    func callOpenLead() {
        cancelAutoNext()
        guard status == .ready, !dialing, gettingReady == nil else { return } // busy, not a missing number
        callWhenReady { [weak self] in self?.problem = "No mobile number on this Salesforce page. Click Next." }
    }

    /// Everything on screen is for the person open in Salesforce: name, page details,
    /// voicemail and follow-ups (written from their page), and Claude's opener for them.
    private func readyToDial(waited: TimeInterval) -> Bool {
        guard let calling, SalesforceTab.currentRecord() == calling else { return false }
        let detailsOK = detailsTried
        let voicemailOK = voicemailScript != nil && voicemailFor == calling && (voicemailUsedDetails || recordDetails == nil)
        // Claude's personal opener; after 10 seconds the instant one (already for them) is enough.
        let openerOK = personalOpenerFor == calling || waited > 10
        return detailsOK && voicemailOK && openerOK
    }

    /// Dials only once the script and follow-ups are for this exact person. Gives up after 25 s.
    private func callWhenReady(countdown: Int = 0, onFail: @escaping () -> Void = {}) {
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            let start = Date()
            while let self, !Task.isCancelled, self.status == .ready {
                self.syncRecord()
                let waited = Date().timeIntervalSince(start)
                if self.readyToDial(waited: waited) {
                    self.gettingReady = nil
                    // Everything matches: "Calling Burcin Sonmezer in 5", with a Wait button.
                    if countdown > 0 {
                        let who = self.calling
                        self.autoNextName = who.flatMap { c in
                            c.firstIndex(of: "\"").map { String(c[c.index(after: $0)...]).replacingOccurrences(of: "\"", with: "") }
                        }
                        for left in stride(from: countdown, through: 1, by: -1) {
                            self.autoNextIn = left
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, self.status == .ready else { self.autoNextIn = nil; return }
                        }
                        self.autoNextIn = nil
                        // Last check: still the same person, still all theirs.
                        guard self.calling == who, self.readyToDial(waited: 99) else {
                            self.problem = "The Salesforce page changed during the countdown. Click Call when ready."
                            return
                        }
                    }
                    if !self.callFromPage() { onFail() }
                    return
                }
                if waited > 25 {
                    self.gettingReady = nil
                    self.problem = "Couldn't get the script ready for this person. Click Call to try again."
                    return
                }
                let name = Screener.firstName(self.calling) ?? "their"
                self.gettingReady = name == "their" ? "Getting the script ready..." : "Getting \(name)'s script ready..."
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.gettingReady = nil
        }
    }

    /// Calls the Mobile number on the open Salesforce page, right from the app (through the
    /// Aircall desktop app). Only if Aircall calling isn't set up does it click the number in Salesforce.
    /// Returns false when the page has no Mobile number.
    @discardableResult
    func callFromPage() -> Bool {
        guard status == .ready, !dialing else { return false }
        syncRecord() // make sure the script and voicemail are for this person
        // The Aircall phone inside the coach (or the desktop app): dial through the API.
        if AircallPhone.isOn || Aircall.canPlaceCalls {
            guard let mobile = SalesforceChrome.mobileNumber() else { return false }
            dialing = true
            dialError = nil
            Task { [weak self] in
                do {
                    try await Aircall.startCall(to: mobile)
                    guard let self else { return }
                    self.dialing = false
                    self.callList.markCurrentCalled()
                    self.pendingDialSince = Date()
                } catch {
                    self?.dialing = false
                    self?.problem = error.localizedDescription
                }
            }
            return true
        }
        guard SalesforceChrome.clickToDial() else { return false }
        waitingForNewCall = false // a new call, even if Chrome still holds the mic
        return true
    }

    private var noMobileSkips = 0

    /// Waits for the lead's Salesforce page to load, then clicks its Mobile number (Aircall in Salesforce dials).
    private func dialFromSalesforcePage(expecting id: String?, countdown: Int = 0) {
        Task { [weak self] in
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.status == .ready else { return }
                if let id, SalesforceChrome.url().flatMap(CallList.recordID) != id { continue } // not loaded yet
                if SalesforceChrome.mobileNumber() != nil {
                    // Page loaded and has a Mobile: dial once their script and follow-ups are ready.
                    self.noMobileSkips = 0
                    self.callWhenReady(countdown: countdown) { [weak self] in self?.problem = "No mobile number on this Salesforce page. Click Next." }
                    return
                }
            }
            // No Mobile number: they're not on the call list. Skip to the next person (up to 20 in a row).
            guard let self else { return }
            self.noMobileSkips += 1
            if self.noMobileSkips <= 20 {
                self.problem = "No mobile number. Skipped to the next person."
                self.nextLead()
            } else {
                self.noMobileSkips = 0
                self.problem = "20 people in a row had no mobile number. Check the Mobile field is on the Salesforce page."
            }
        }
    }

    /// After a voicemail: the text and LinkedIn note to send. Stays after the call until checked off.
    @Published var followUp: FollowUp? { didSet { followUpChanged() } }

    /// After a call that's done (no redial): sending the text is the cue to move on.
    @Published private(set) var waitingForText = false
    private var textWasDone = false

    private func followUpChanged() {
        let done = followUp?.textDone == true
        defer { textWasDone = done }
        guard waitingForText, status == .ready else { return }
        // Text just sent, or the card was closed: on to the next person.
        if (done && !textWasDone) || followUp == nil {
            waitingForText = false
            startNextSequence()
        }
    }

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
    /// Dials, pickups, texts, LinkedIn notes and more, counted on this Mac.
    let touchpoints = Touchpoints()
    /// Real free time from the booking calendar (Calendly or Google), for booking.
    let availability = Availability()
    /// Meeting times already offered on this call, and the next two to offer.
    private var offeredTimes: Set<Date> = []
    private var codeByDate: [Date: String] = [:]
    @Published private(set) var nextOffer: [Date] = []

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
    private let hold: TimeInterval = 4
    /// A line stays until the rep has said it (about 4 words heard from the rep),
    /// or this many seconds pass. New lines wait, so nothing changes mid-read.
    private let lockSeconds: TimeInterval = 15
    private var repWordsSinceShown = 0
    private var repWordsInCall = 0

    /// True while the line on screen is new and the rep hasn't said it yet.
    private var lineIsFresh: Bool {
        (kind == .reply || kind == .opener) && !suggestion.say.isEmpty
            && repWordsSinceShown < 4 && Date().timeIntervalSince(shownAt) < lockSeconds
    }

    private var active = false

    /// Only the visible coach screen reacts to calls (not while the audio check runs).
    func activate(_ on: Bool) {
        active = on
        if on { onAppear() } else if status != .ready { nextCall() }
    }

    func onAppear() {
        // Redraw the coach when the call list changes (it lives in its own object).
        if listWatcher == nil {
            listWatcher = callList.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            leadsWatcher = leads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            // A new lead loaded between calls: write its opener and voicemail.
            leadDetailsWatcher = leads.$details.sink { [weak self] details in
                guard let details else { return }
                Task { @MainActor in
                    guard let self, self.status == .ready, details.id != self.appliedLeadID else { return }
                    self.applyLead()
                }
            }
            Task { await leads.start() }
        }
        if suggestion.say.isEmpty, !thinking { prepareOpener() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Call lifecycle

    /// Points the coach at the record open in Chrome right now: name, opener, voicemail,
    /// follow-ups and status all for that one person. Called every second between calls,
    /// and always right before dialing, so nothing from the last person carries over.
    private func syncRecord() {
        guard !leads.isActive else { return }
        let record = SalesforceTab.currentRecord()
        refreshRelationship()
        guard record != calling || (detailsPending && record != nil) else { return }
        detailsPending = false
        calling = record
        if recordKey() != currentAttemptKey { currentAttemptKey = nil; lastCallAnswered = true }
        recordDetails = nil
        detailsTried = false
        personalOpenerFor = nil
        prepareOpener()
        prepareVoicemail() // right away for this person; again with details below
        // Salesforce fills in the page after the title changes: read the details a moment later.
        detailsTask?.cancel()
        detailsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.calling == record, record != nil else { return }
            self.recordDetails = SalesforceTab.pageText()
            self.detailsTried = true
            if self.recordDetails != nil, self.status == .ready { self.prepareOpener() }
            self.prepareVoicemail()
        }
    }

    private func tick() {
        guard active else { return }
        let onCall = AudioProcess.anyCallApp(in: AudioProcess.others())
        // Between calls, notice which record is open so the opener uses their name.
        // Dialed from the app: start listening once the Aircall app picks up the call (or after 8 s).
        if let since = pendingDialSince, status == .ready {
            // Start listening almost right away, so a "straight to voicemail" greeting is heard from word one.
            if AudioProcess.aircallAppOnCall(in: AudioProcess.others()) || Date().timeIntervalSince(since) > 1 {
                pendingDialSince = nil
                waitingForNewCall = false
                startCall()
            }
            return
        }
        if status == .ready, !leads.isActive, !onCall || waitingForNewCall {
            tabTicks += 1
            if tabTicks % 2 == 0 {
                callList.captureIfListView()
                callList.refreshUpNext()
                syncRecord()
            }
        }
        switch status {
        case .ready where onCall:
            if waitingForNewCall {
                // Chrome is still holding the last call's mic/speaker: start only when Aircall shows a new call.
                checkAircallForNewCall()
            } else {
                startCall()
            }
        case .ready:
            waitingForNewCall = false // Chrome let go, so the next time it grabs the mic is a new call
        case .live:
            if onCall { heardCallAudio = true }
            // Only count quiet after the call's audio has shown up once, so a call that's
            // still ringing (we start listening right after dialing) isn't ended early.
            if !startedByHand, heardCallAudio || Date().timeIntervalSince(callStartedAt) > 45 {
                quietTicks = onCall ? 0 : quietTicks + 1
                if quietTicks >= 6 { endCall(); return } // Chrome let go of the call for 3 seconds
            }
            checkAircallEveryFewSeconds()
            if AudioProcess.doubleCall(in: AudioProcess.others()) {
                problem = "Two calls at once: Aircall is signed in here and in Salesforce. Log out of the Aircall panel in Salesforce."
            }
        default:
            break
        }
    }

    /// The rep clicked End call (or Aircall/Chrome says it's over): reset for the next call.
    func endCall() {
        guard status != .ready else { return }
        // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
        // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
        let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
            && Date().timeIntervalSince(callStartedAt) < 12
            && !turns.contains { $0.speaker == .prospect }
        if quickFail, let key = currentAttemptKey {
            let fails = DialHistory.logFailedConnect(key)
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true // no redial
            problem = fails >= 2 ? "Didn't connect again. Bad number: taken off your list." : "Didn't connect (bad number or network). Moving on."
            startNextSequence()
            return
        }
        if badNumberThisCall {
            // Number doesn't work: no voicemail, no text, no redial. Off the list, on to the next.
            badNumberThisCall = false
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true
            problem = "Bad number. Taken off your list."
            startNextSequence()
            return
        }
        // 2nd try went to voicemail: they've had both calls. Move on by itself.
        let moveOn = sawVoicemail && currentAttempts >= 2
        nextCall()
        waitingForNewCall = true
        endedAt = Date()
        if !shouldOfferRedial, let f = followUp {
            // Voicemail, done with them: send the text, then the next call starts.
            if f.textDone { startNextSequence() } else { waitingForText = true }
        } else if moveOn {
            startNextSequence()
        }
    }

    // MARK: Auto next

    /// Seconds left before the app moves to the next lead by itself. Nil = not counting.
    @Published private(set) var autoNextIn: Int?
    private var autoNextTask: Task<Void, Never>?

    /// Who's next, for the countdown banner.
    var nextLeadName: String? {
        if leads.isActive { return leads.nextRow?.name }
        if case .ready(let name, _, _) = callList.state { return name }
        return nil
    }

    /// Counts down 5 seconds, then loads the next lead (and calls them, if "Next calls right away" is on).
    private func startAutoNext() {
        guard nextLeadName != nil else { return }
        autoNextTask?.cancel()
        autoNextTask = Task { [weak self] in
            for left in stride(from: 5, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                // A call started some other way: stop counting.
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled else { return }
            self.nextLead()
        }
    }

    /// The rep clicked Wait (or moved on by hand).
    func cancelAutoNext() {
        waitingForText = false
        autoNextName = nil
        readyTask?.cancel()
        gettingReady = nil
        autoNextTask?.cancel()
        autoNextTask = nil
        autoNextIn = nil
    }
    private var endedAt = Date.distantPast

    /// After a call ends while Chrome still holds the mic, don't treat that as a new call.
    private var waitingForNewCall = false
    private var callStartedAt = Date.distantPast
    private var heardCallAudio = false

    private func checkAircallForNewCall() {
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        aircallCheck = Task { [weak self] in
            let since = self?.endedAt ?? Date()
            let onCall = await Aircall.lineIsOnCall(since: since)
            guard let self else { return }
            self.aircallCheck = nil
            if onCall == true, self.status == .ready, self.waitingForNewCall {
                self.waitingForNewCall = false
                self.startCall()
            }
        }
    }

    // Aircall says when the call is over. Asked every 2 seconds during a call; two "no call"
    // answers in a row end it (so one slow answer can't end a live call).
    private var aircallTicks = 0
    private var aircallSaysOver = 0
    private var aircallCheck: Task<Void, Never>?

    private func checkAircallEveryFewSeconds() {
        aircallTicks += 1
        guard aircallTicks % 4 == 0, aircallCheck == nil, Aircall.isSetUp else { return }
        // Give Aircall a moment to register a brand-new call before trusting a "no".
        guard Date().timeIntervalSince(callStartedAt) > 5 else { return }
        aircallCheck = Task { [weak self] in
            let onCall = await Aircall.lineIsOnCall()
            guard let self else { return }
            self.aircallCheck = nil
            guard self.status == .live, let onCall else { return }
            self.aircallSaysOver = onCall ? 0 : self.aircallSaysOver + 1
            if self.aircallSaysOver >= 2 { self.endCall() }
        }
    }

    func startByHand() {
        waitingForNewCall = false
        startedByHand = true
        startCall()
    }

    private func startCall() {
        problem = nil
        guard startAudio() else { return }
        if !leads.isActive { callList.markCurrentCalled() } // so Next skips them today (Chrome list)
        if let key = recordKey() {
            currentAttemptKey = key
            attempts[key, default: 0] += 1
        }
        touchpoints.log(.dial)
        if let key = currentAttemptKey { DialHistory.logDial(key) }
        // Calling someone new: the last person's follow-up card goes away.
        if let f = followUp, f.key != nil, f.key != currentAttemptKey { followUp = nil }
        status = .live
        quietTicks = 0
        availability.refresh() // fresh free times for this call
        callOpener = kind == .opener ? openerStyle : nil
        goalHit = false
        sawVoicemail = false
        stagesSeen = []
        callStartedAt = Date()
        heardCallAudio = false
        aircallSaysOver = 0
        aircallTicks = 0
        journeyStep = 0
        history = Array(history.suffix(1)) // keep the opener as the first line
        historyIndex = nil
        repWordsInCall = 0
        repWordsSinceShown = 0
        offeredTimes = []
        codeByDate = [:]
        nextOffer = []
        screenerActive = false
        openerBeforeScreener = nil
        voicemailActive = false
        badNumberThisCall = false
        mailboxFullShown = false
        followUpThisCall = false
        cancelAutoNext()
        if voicemailScript == nil { prepareVoicemail() }
        firstProspectAt = nil
        lastWordsAt = nil
    }

    /// Counts the call that just ended. Picked up = a real person talked (not voicemail, not
    /// only a screener). Conversation = they kept talking: 3+ turns, or 45+ seconds after pickup.
    private func logTouchpoints(answered: Bool) {
        if sawVoicemail { touchpoints.log(.voicemail) }
        guard answered else { return }
        touchpoints.log(.pickup)
        if let key = currentAttemptKey { DialHistory.logPickup(key) }
        let prospectTurns = turns.filter { $0.speaker == .prospect }.count
        let talked = firstProspectAt.map { Date().timeIntervalSince($0) } ?? 0
        if prospectTurns >= 3 || talked >= 45 { touchpoints.log(.conversation) }
        if goalHit { touchpoints.log(.meeting) }
    }

    /// Clears everything about this prospect and gets the next opener ready.
    func nextCall() {
        if status != .ready {
            // Reached a person = they spoke, and it wasn't a voicemail or only a screener.
            let theySpoke = turns.contains { $0.speaker == .prospect }
            lastCallAnswered = theySpoke && !sawVoicemail && !screenerActive
            logTouchpoints(answered: lastCallAnswered)
        }
        history = []
        historyIndex = nil
        journeyStep = 0
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
        if leads.isActive {
            applyLead()
        } else {
            calling = SalesforceTab.currentRecord()
            recordDetails = calling == nil ? nil : SalesforceTab.pageText()
            prepareOpener()
            prepareVoicemail()
        }
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
        pendingStop?.cancel() // a new call: keep the old tap from being removed later
        pendingStop = nil
        guard let deepgramKey = Keychain.read(.deepgram) else {
            problem = "Add your Deepgram key in Settings."
            return false
        }
        let chrome = AudioProcess.callAudioTargets(in: AudioProcess.others())
        guard !chrome.isEmpty else {
            problem = "Can't hear the call yet. Open the Aircall app (or Aircall in Chrome) and start the call."
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

    /// Stops listening. Transcription stops right away, but the audio tap is removed a few
    /// seconds later: tearing it down while Aircall plays the hang-up tone makes that tone
    /// stutter and repeat.
    private func stopAudio() {
        streams.closeAll()
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.pendingStop = nil
            self.capture.stop()
        }
    }
    private var pendingStop: Task<Void, Never>?
    /// Who the ready-made voicemail was written for, and whether it used their Salesforce page.
    private var voicemailFor: String?
    private var voicemailUsedDetails = false
    /// The page's details were read (or tried) for the person on screen.
    private var detailsTried = false
    /// Who Claude's personal opener on screen is for.
    private var personalOpenerFor: String?
    private var instantOpenerID = -1
    /// Who the countdown is for.
    @Published private(set) var autoNextName: String?
    /// "Getting Burcin's script ready..." while the app waits to dial.
    @Published private(set) var gettingReady: String?
    private var readyTask: Task<Void, Never>?
    private var detailsPending = false

    private func openStream(_ speaker: Speaker, key: String) -> DeepgramStream {
        DeepgramStream(apiKey: key, keyterms: useKeyterms ? DeepgramStream.defaultKeyterms : []) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: speaker) }
        }
    }

    private func handle(_ event: DeepgramStream.Event, from speaker: Speaker) {
        guard status == .live else { return }
        switch event {
        case .transcript(let text, let isFinal, let speechFinal):
            if speaker == .prospect {
                // Check the recent words together, so a phrase split across chunks still matches.
                let recent = String(((turns.last { $0.speaker == .prospect }?.text ?? "") + " " + text).suffix(400))
                let early = repWordsInCall < 3 && Date().timeIntervalSince(firstProspectAt ?? Date()) < 15
                let firstWords = turns.contains { $0.speaker == .rep } ? "" : (prospectSoFar + " " + text)
                if BadNumber.detects(recent) {
                    if !badNumberThisCall { markBadNumber() }
                } else if Voicemail.detects(recent, earlyInCall: early)
                    || (!screenerActive && !Screener.detects(firstWords) && Voicemail.longGreeting(firstWords, earlyInCall: early)) {
                    if !voicemailActive || (Voicemail.mailboxFull(recent) && !mailboxFullShown) {
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                } else if !voicemailActive, !screenerActive, !stagesSeen.contains("Screener"), Screener.detects(recent) {
                    showScreenerLine()
                }
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

    /// Everything the prospect side has said this call (finished words only).
    private var prospectSoFar: String {
        turns.filter { $0.speaker == .prospect }.map(\.text).joined(separator: " ")
    }

    /// The rep clicked "Voicemail": the app missed it, so show the message now.
    func markVoicemail() {
        guard status == .live, !voicemailActive else { return }
        showVoicemail(mailboxFull: false)
    }

    private func addFinal(_ text: String, from speaker: Speaker) {
        lastWordsAt = Date()
        if speaker == .rep {
            let count = text.split(separator: " ").count
            repWordsSinceShown += count
            repWordsInCall += count
        }
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

    /// The meeting times Claude may offer, with stable codes for this call, and which two to offer next.
    private func bookingText() -> String? {
        let slots = availability.offerSlots()
        guard !slots.isEmpty else { return nil }
        for slot in slots where codeByDate[slot] == nil {
            codeByDate[slot] = "T\(codeByDate.count + 1)"
        }
        let next = pickNextPair(from: slots)
        nextOffer = next
        let list = slots.map { slot in
            "\(codeByDate[slot]!): \(availability.label(slot))" + (offeredTimes.contains(slot) ? " (already offered)" : "")
        }.joined(separator: "\n")
        let nextCodes = next.compactMap { codeByDate[$0] }.joined(separator: " or ")
        return """
        Meeting times open on the host's calendar (exact start times, \(availability.zoneName) time). Offer only these:
        \(list)
        When asking for the meeting, offer exactly these two next: \(nextCodes). Say them naturally, like "Tuesday at 10 or Wednesday at 2:30".
        If they turn times down, the next message gives you new ones; never re-offer a time marked already offered.
        If the prospect names a time, check the list. If it's there, confirm it. If not, offer the closest listed time.
        Whenever your SAY offers or confirms specific times, add a last line: OFFERED: <their codes, comma separated>.
        """
    }

    /// Two not-yet-offered times: the soonest, plus one on another day (or at least 3 hours apart).
    private func pickNextPair(from slots: [Date]) -> [Date] {
        let fresh = slots.filter { !offeredTimes.contains($0) }
        guard let first = fresh.first else { return [] }
        let cal = Calendar.current
        let second = fresh.dropFirst().first { !cal.isDate($0, inSameDayAs: first) }
            ?? fresh.dropFirst().first { $0.timeIntervalSince(first) >= 3 * 3600 }
            ?? fresh.dropFirst().first
        return [first] + (second.map { [$0] } ?? [])
    }

    /// The rep asked for a different line right now. Skips the wait and the hold.
    func newLine(extra: String = "The rep asked for a different line than the last one.") {
        guard status == .live, !voicemailActive else { return }
        let latest = uncoached.trimmed.isEmpty ? (turns.last { $0.speaker == .prospect }?.text ?? "") : uncoached.trimmed
        uncoached = ""
        shownAt = .distantPast // no hold for a line the rep asked for
        repWordsSinceShown = 99
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ) + "\n" + extra)
    }

    /// The rep clicked "Other times": count the current pair as turned down.
    func skipOfferedTimes() {
        offeredTimes.formUnion(nextOffer)
        nextOffer = pickNextPair(from: availability.offerSlots())
    }

    /// The carrier says the number doesn't work: show it, and skip voicemail and follow-ups.
    private var badNumberThisCall = false
    private func markBadNumber() {
        badNumberThisCall = true
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey { DialHistory.markBadNumber(key) }
        seq += 1
        show(Suggestion(say: "Bad number. Hang up. The next call starts by itself.", cue: "The carrier says this number doesn't work.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
    }

    /// Instant voicemail card: the script written before the call, or "mailbox full, move on".
    private func showVoicemail(mailboxFull: Bool) {
        voicemailActive = true
        sawVoicemail = true
        screenerActive = false
        coachTask?.cancel()
        specTimer?.cancel()
        holdTask?.cancel()
        pending = nil
        specBasis = nil
        uncoached = ""
        seq += 1
        startFollowUp()
        if mailboxFull {
            mailboxFullShown = true
            show(Suggestion(say: currentAttempts < 2 ? "Mailbox is full. Hang up and click Redial." : "Mailbox is full. Hang up. The next call starts by itself.",
                            cue: "No message possible.",
                            stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
        } else if var script = voicemailScript, voicemailFor == calling {
            if currentAttempts < 2 {
                script.cue = "1st try: hang up and click Redial. Leave this message on the 2nd try."
            }
            show(script, id: seq, kind: .voicemail)
        } else {
            // Not written yet: ask now. The beep usually gives a few seconds.
            show(Suggestion(say: "Writing your voicemail...", cue: "Wait for the beep.", stage: "Voicemail", sayComplete: true),
                 id: seq, kind: .voicemail)
            ask(.voicemail, user: CoachPrompt.voicemail(calling: calling, details: recordDetails))
        }
    }

    /// Sets up the follow-up card for this prospect, filled from the pre-written voicemail if ready.
    private func startFollowUp() {
        let name = calling.flatMap { c -> String? in
            guard let open = c.firstIndex(of: "\""), let close = c.lastIndex(of: "\""), open < close else { return nil }
            return String(c[c.index(after: open)..<close])
        }
        // A fresh card for every voicemail, so nothing (like an old error) carries over.
        // Same person as last time (2nd try): keep what was already sent, so they don't get it twice.
        let lead = leads.isActive ? leads.details : nil
        let key = recordKey()
        let earlier = followUp?.key != nil && followUp?.key == key ? followUp : nil
        followUpThisCall = true
        followUp = FollowUp(key: key,
                            prospect: lead?.name ?? name,
                            text: earlier?.text ?? "",
                            linkedin: earlier?.linkedin ?? "",
                            textDone: earlier?.textDone ?? key.map(DialHistory.textedToday) ?? false,
                            linkedinDone: earlier?.linkedinDone ?? key.map(DialHistory.linkedInToday) ?? false,
                            phone: lead?.callNumber ?? Aircall.phone(in: recordDetails) ?? (leads.isActive ? nil : SalesforceChrome.mobileNumber()) ?? "",
                            linkedinURL: lead?.linkedIn ?? Self.linkedInProfile(details: recordDetails),
                            linkedinMessage: earlier?.linkedinMessage ?? "",
                            linkedinMessageDone: earlier?.linkedinMessageDone ?? key.map(DialHistory.linkedInMessageToday) ?? false)
        if followUp?.textDone == true, earlier == nil { followUp?.textStatus = "Already texted today" }
        if let script = voicemailScript, voicemailFor == calling { fillFollowUp(from: script) }
        else if voicemailTask == nil || voicemailFor != calling { prepareVoicemail() } // it fills the card when done
    }

    private var followUpThisCall = false

    /// Fills in the text and LinkedIn note. The rep sends each one with a button.
    private func fillFollowUp(from s: Suggestion) {
        guard followUpThisCall, var f = followUp else { return }
        if f.text.isEmpty { f.text = s.textMessage }
        if f.linkedin.isEmpty { f.linkedin = s.linkedin }
        if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
        followUp = f
    }

    /// Sends the follow-up text through Aircall and checks it off.
    func sendFollowUpText() {
        guard let f = followUp, !f.text.isEmpty, f.textStatus != "Sending..." else { return }
        if let key = f.key, DialHistory.textedToday(key) {
            followUp?.textStatus = "Already texted today. Not sent again."
            followUp?.textDone = true
            return
        }
        followUp?.textStatus = "Sending..."
        Task { [weak self] in
            do {
                try await Aircall.sendText(to: f.phone, body: f.text)
                self?.touchpoints.log(.text)
                if let key = f.key { DialHistory.logText(key) }
                self?.followUp?.textStatus = "Sent"
                self?.followUp?.textDone = true
            } catch {
                self?.followUp?.textStatus = error.localizedDescription
            }
        }
    }

    /// Opens their LinkedIn profile (from the Salesforce record), with the note already copied.
    /// Falls back to a name + company search only when the record has no LinkedIn link.
    /// - Parameter message: true = copy the direct message (already connected), false = the connection note.
    func openLinkedIn(message: Bool = false) {
        guard let f = followUp else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message ? f.linkedinMessage : f.linkedin, forType: .string)
        // The message only gets copied: the profile is already open from the note button.
        if message {
            if followUp?.linkedinMessageDone != true, !(f.key.map(DialHistory.linkedInMessageToday) ?? false) {
                touchpoints.log(.linkedinMessage)
                if let key = f.key { DialHistory.logLinkedInMessage(key) }
            }
            followUp?.linkedinMessageDone = true
            return
        }
        if let profile = f.linkedinURL ?? (leads.isActive ? nil : Self.linkedInProfile(details: recordDetails)) {
            NSWorkspace.shared.open(profile)
        } else {
            let query = [f.prospect, recordCompany].compactMap { $0 }.joined(separator: " ")
            if let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://www.linkedin.com/search/results/people/?keywords=\(q)") {
                NSWorkspace.shared.open(url)
            }
        }
        // Count once per person per day.
        if message {
            if followUp?.linkedinMessageDone != true, !(f.key.map(DialHistory.linkedInMessageToday) ?? false) {
                touchpoints.log(.linkedinMessage)
                if let key = f.key { DialHistory.logLinkedInMessage(key) }
            }
            followUp?.linkedinMessageDone = true
            return
        }
        if followUp?.linkedinDone != true, !(f.key.map(DialHistory.linkedInToday) ?? false) {
            touchpoints.log(.linkedin)
            if let key = f.key { DialHistory.logLinkedIn(key) }
        }
        followUp?.linkedinDone = true
    }

    /// The profile link from the record: the LinkedIn field's link on the page, or the URL in the page text.
    static func linkedInProfile(details: String?) -> URL? {
        var raw = SalesforceChrome.linkedInProfile()
        if raw == nil, let details,
           let r = details.range(of: #"linkedin\.com/in/[A-Za-z0-9\-_%]+"#, options: .regularExpression) {
            raw = "https://www." + details[r]
        }
        guard var link = raw else { return nil }
        if link.hasPrefix("http://") { link = "https://" + link.dropFirst("http://".count) }
        return URL(string: link)
    }

    /// The company line from the Salesforce page, if it shows one (helps LinkedIn find the right person).
    private var recordCompany: String? {
        guard let lines = recordDetails?.components(separatedBy: "\n") else { return nil }
        for (i, line) in lines.enumerated() where ["Company", "Account Name"].contains(line.trimmingCharacters(in: .whitespaces)) {
            if i + 1 < lines.count { return lines[i + 1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Writes this prospect's voicemail in the background, so it's instant when needed.
    private func prepareVoicemail() {
        voicemailTask?.cancel()
        voicemailScript = nil
        let forWho = calling
        let usedDetails = detailsTried
        voicemailFor = forWho
        guard let key = Keychain.read(.anthropic) else { return }
        let client = CoachSpeed.fastest.client(apiKey: key) // voicemails always use Haiku: fast
        let system = self.system
        let user = CoachPrompt.voicemail(calling: calling, details: recordDetails)
        voicemailTask = Task { [weak self] in
            var text = ""
            do {
                try await client.stream(system: system, user: user) { text = $0 }
            } catch {
                return
            }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            s.stage = "Voicemail"
            if !Task.isCancelled, !s.say.isEmpty, self?.calling == forWho {
                self?.voicemailUsedDetails = usedDetails
                self?.voicemailScript = s
                if self?.voicemailActive == true { self?.fillFollowUp(from: s) }
            }
            if !Task.isCancelled { self?.voicemailTask = nil }
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
        guard status == .live, !screenerActive, !voicemailActive, !lineIsFresh else { return }
        let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
        guard let last = text.last, ".?!".contains(last), isMeaningful(text) else { return }
        specTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled,
                  (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
                  normalized(text) != self.specBasis else { return }
            self.ask(.reply, user: CoachPrompt.reply(
                turns: self.turns, latest: text, calling: self.calling, details: self.recordDetails, style: self.callOpener,
                openTimes: self.bookingText()
            ), early: text)
        }
    }

    /// The prospect stopped talking. Decide if the rep needs a new line.
    private func prospectFinished() {
        specTimer?.cancel()
        let said = uncoached.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
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
        // The rep hasn't said the line on screen yet: keep it. Their words stay queued
        // and are answered once the rep has spoken and they reply.
        if lineIsFresh {
            latestProspect = said
            return
        }
        uncoached = ""
        latestProspect = said
        // A plain "Hello?" is already answered by the opener on screen.
        let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
        // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
        let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
        guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else { return }
        ask(.reply, user: CoachPrompt.reply(
            turns: turns, latest: said, calling: calling, details: recordDetails, style: callOpener,
            openTimes: bookingText()
        ))
    }

    // MARK: Claude

    private func prepareOpener() {
        // A ready-to-read line right away (from the opener template), so there's always a script
        // on screen before the phone rings. Claude's personal version replaces it when it's ready.
        seq += 1
        instantOpenerID = seq
        show(instantOpener(for: calling), id: seq, kind: .opener)
        ask(.opener, user: CoachPrompt.opener(calling: calling, details: recordDetails, style: openerStyle))
    }

    /// The opener template filled in with their first name, your name and your company. No waiting.
    private func instantOpener(for calling: String?) -> Suggestion {
        var t = openerStyle?.template ?? Opener.all[0].template
        if t.contains("[a ") { t = Opener.all[0].template } // needs Claude to fill in; use the plain one
        let rep = (UserDefaults.standard.string(forKey: "repName") ?? "").trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "[first name]", with: Screener.firstName(calling) ?? "there")
            .replacingOccurrences(of: "[rep]", with: rep.isEmpty ? "[your name]" : rep)
            .replacingOccurrences(of: "[company]", with: shortCompany)
        return Suggestion(say: t, cue: openerStyle?.name ?? "Opener", stage: "Opener", sayComplete: true)
    }

    /// "Clarity" from the campaign's company description.
    private var shortCompany: String {
        let c = campaign.company
        if c.localizedCaseInsensitiveContains("Clarity") { return "Clarity" }
        let first = c.components(separatedBy: CharacterSet(charactersIn: ",.;:")).first ?? ""
        let words = first.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? "[company]" : words
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
        // Voicemails always use Haiku, so the message is ready before the beep.
        let client = (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)
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
            if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
            suggestion = s // same answer, still streaming in
            note(s)
            return
        }
        // The call is live and someone already talked: keep the opener the rep is reading.
        if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect }) { return }
        let waited = Date().timeIntervalSince(shownAt)
        if kind == .opener || kind == .voicemail || shownID == 0 || waited >= hold {
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
        if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
        pending = nil
        shownID = id
        shownAt = Date()
        repWordsSinceShown = 0
        suggestion = s
        historyIndex = nil
        if !s.say.isEmpty, s.sayComplete || kind != .reply { history.append((s: s, kind: kind)) }
        self.kind = kind
        problem = nil
        note(s)
    }

    /// Bookkeeping for what a line tells us: stage reached, times offered, goal, voicemail.
    private func note(_ s: Suggestion) {
        if status != .ready, !s.stage.isEmpty {
            stagesSeen.insert(s.stage)
            trackJourney(s.stage)
        }
        if voicemailActive, !s.textMessage.isEmpty || !s.linkedin.isEmpty || !s.linkedinMessage.isEmpty { fillFollowUp(from: s) }
        // Remember which meeting times this line offered, so the next ones are different.
        if !s.offered.isEmpty {
            let dates = s.offered.compactMap { code in codeByDate.first { $0.value == code }?.key }
            offeredTimes.formUnion(dates)
            nextOffer = pickNextPair(from: availability.offerSlots())
        }
        if s.stage == "Closing" { availability.refreshIfOlder() } // fresh times while booking
        if s.stage == "Goal reached" { goalHit = true }
        if s.stage == "Voicemail" { sawVoicemail = true }
    }
}
