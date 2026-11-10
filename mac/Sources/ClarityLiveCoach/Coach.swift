import AppKit
import AVFoundation
import Combine
import CoreAudio
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
    /// Phone tree: the keys to press now (0-9, * and #), for the one-click button.
    var keys = ""

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
            else if trimmed.hasPrefix("KEYS:") {
                s.keys = String(trimmed.dropFirst(5).filter { "0123456789*#".contains($0) }.prefix(12))
            }
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

        When the campaign has its own call script, the script leads. Follow its lines and its order, in its words.
        Go off-script only when you're highly confident a different line moves the call toward the campaign objective
        better, for example the prospect said something the script doesn't cover, or the script's next line no longer
        fits what they just said. Then write it in the script's voice and get back to the script as soon as you can.
        The method below fills the gaps; it never overrides the script.

        Getting past a gatekeeper (receptionist, assistant, operator, "who's calling?"). Adapt the campaign's
        opener for this automatically; the goal is to be put through, not to pitch:
        - Sound expected and brief. First name for the prospect, first name for the rep: "Hi, it's Mason for AJ.
          Is AJ around?" Calm, warm, a little informal, like a peer calling a peer.
        - Ask for help, don't sell. Never pitch the gatekeeper. One short, true reason only if asked, tied to the
          prospect's world in the script's words ("It's about how AJ's team handles ops admin. Easy to explain
          once we connect.").
        - "What's this regarding?": the one-line reason, then straight back to the ask: "Could you put me through?"
        - "Are they expecting your call?": honest: "Not yet. Worth a minute of AJ's time, though. Is AJ in?"
        - "They're busy / in a meeting": get the next best thing: their direct line or extension, the best time
          to call, or their email. Use the gatekeeper's name if they gave it.
        - "Send an email": "Happy to. What's the best address for AJ?" then ask when AJ is usually free.
        - Never lie, never claim a relationship or a prior conversation that didn't happen.
        - Use the prospect's name, not "he" or "she", unless the gatekeeper used one first.
        - Once the prospect is on the line: back to the script's opener.

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
        - "We're all good", "all taken care of", "we're set", "we already have someone": don't accept it and don't exit.
          Acknowledge it warmly, then go straight for a meeting anyway, framed as a free health check or audit of
          their systems: a second set of eyes, no cost, they keep whatever they learn. For example: "Love that. Most
          teams who say that still find a few gaps. Worth a free 20-minute health check, so you know for sure?"
          Then offer two specific times. Only exit if they say no to the health check too.

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

    static func opener(calling: String?, details: String?, style: Opener?, scriptOpener: String? = nil) -> String {
        guard let style else {
            let given = scriptOpener.map { "The script's opener, exactly as written: \"\($0)\"\n" } ?? ""
            return """
            \(about(calling, details))\(given)The call has not connected yet. Give the opener the rep should say when they pick up.
            Use the script's own opener (above, or the campaign's Opening section, or the first line of the original
            script). Say it the way the script says it: same words, same order, same tone, and nothing in front of it
            (if the script starts "Is this ___?", the line starts "Is this", not "Hi ___, this is ___").
            Fill in the blanks (___, [Name], {first name}) with their first name, the rep's name or the company.
            Then check it against what you know about this person. If a part of the script doesn't fit them, change
            only that part, as little as possible, in the script's voice. For example: the script says "a fellow
            Portland entrepreneur" but they're not in Portland or don't run a business; the script names an industry,
            role or tool that isn't theirs; the script assumes something their Salesforce page contradicts. Never
            invent facts about them. If nothing needs changing, use the script as is. Don't add a pitch or a greeting
            the script doesn't have. Only write a different opener if you're highly confident it serves the script's
            goal better for this person, and keep it as short as the script's.
            CUE: one short delivery tip from the script's tone, plus "(adjusted: <what changed>)" if you changed anything.
            """
        }
        return """
        \(about(calling, details))The call has not connected yet. Write the opener using this proven structure. \
        Keep its wording and shape; only fill in the brackets. [company] is the rep's company from the campaign. \
        If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
        Opener: \(style.template)
        Put the opener's name in the CUE: "\(style.name) opener".
        """
    }

    /// A phone menu is playing. Plan the best route to the owner.
    static func phoneTree(menu: String, calling: String?, details: String?, repSaid: String) -> String {
        """
        \(about(calling, details))The call reached an automated phone menu (phone tree). Everything it has said so far
        (speech-to-text, so expect small errors):
        "\(menu)"
        \(repSaid.isEmpty ? "" : "Keys or words the rep has already used: \(repSaid)\n")
        Goal: reach the person above, or if they're the owner or a decision maker, the fastest route to a live
        person who can put the rep through to them. Pick the highest-leverage option from what the menu actually
        offers. Usually best first: dial by name or the company directory (spell their last name on the keypad:
        2=ABC 3=DEF 4=GHI 5=JKL 6=MNO 7=PQRS 8=TUV 9=WXYZ), their extension if known, an option for the owner,
        management or executive office, then sales (sales lines answer fast and can transfer), then the operator
        (0). Avoid support queues, billing, hours, locations and anything that ends in a voicemail box.
        If the menu hasn't listed its options yet, say to wait for them, and what to listen for.
        If the latest words are clearly a live person, not a recording, start your answer with the line HUMAN,
        then give what the rep should say to them. A receptionist or assistant: the campaign's opener adapted for
        getting through to the person (see "Getting past a gatekeeper"), in the script's voice. The person
        themselves: the script's opener.
        Answer in this format:
        SAY: <the exact keys to press now, or what to say, and why in a few words>
        KEYS: <only the digits to press now, like 3 or 7467 (0-9, * and #); leave empty if the rep should wait or talk>
        CUE: <the backup plan if that doesn't work>
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
    static func voicemail(calling: String?, details: String?, earlierTexts: [String] = [], earlierMessages: [String] = [],
                          history: String = "") -> String {
        let past = history.isEmpty ? "" : """
        What the rep has already done with this person:
        \(history)

        """
        let earlierLinkedIn = earlierMessages.isEmpty ? "" : """
        This will be LinkedIn message number \(earlierMessages.count + 1). LinkedIn messages already sent (oldest first):
        \(earlierMessages.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
        The new LINKEDIN MESSAGE must be clearly different from every one of these: a new angle or question and new wording.

        """
        let earlier = earlierTexts.isEmpty ? "" : """
        This will be text number \(earlierTexts.count + 1) to this person. Texts already sent (oldest first):
        \(earlierTexts.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
        The new TEXT must be clearly different from every one of these: a new angle or question and new wording.
        Don't reuse their opening words. Keep it short and friendly; later texts can be lighter (for example,
        a quick "should I stop reaching out?" by the 4th or 5th text).

        """
        return """
        \(about(calling, details))\(past)\(earlier)\(earlierLinkedIn)If this call goes to voicemail, what should the rep say after the beep?
        One voice for everything you write here. The voicemail, TEXT, LINKEDIN and LINKEDIN MESSAGE all come from
        the campaign above: its opening, its angle, its offer, its tone, and any voicemail, text or LinkedIn wording
        it gives. Follow the campaign over the defaults below whenever they differ.
        Templates come first: if the campaign or its script has a voicemail script, the voicemail is that script
        word for word, with only the blanks and placeholders filled in. If the campaign or its script has a text message template (a missed call text, a text
        after a voicemail, or any text the rep sends), the TEXT line must be that template word for word, with only
        the name, rep and company placeholders filled in (for a later text, use the script's matching follow-up
        template if it has one). Same for LinkedIn: a connection note or request template goes in LINKEDIN word for
        word, a LinkedIn message template goes in LINKEDIN MESSAGE, and with no LinkedIn template, use the text
        template there too. Only write your own when the campaign has no template. Write the voicemail first, then
        make every TEXT and LinkedIn line sound like the same person who just left that voicemail: the same way the
        rep introduces themselves (if the voicemail says something like "a fellow Portland entrepreneur", so do the
        text and LinkedIn note), the same reason for reaching out, the same warmth and plainness. Never switch to
        a different pitch or a more formal, salesy tone in the written follow-ups.
        Voicemail: under 20 seconds, about 40 words. In this order: their first name; the rep's name and how the
        campaign introduces them; one reason tied to the campaign's angle and to something specific about them,
        their role or their company (from the Salesforce facts, or a common pain for their title if there are none);
        then one closing line that fits the history above:
        - No text sent yet: "I'll send you a quick text so you have my number."
        - A text was already sent: don't promise a first text again. Mention it instead, for example
          "I sent you a text the other day, so you have my number" (use the real timing: today, yesterday, a few days ago).
        - A LinkedIn connection request or message was already sent: you can mention it, for example
          "I also sent you a connection request on LinkedIn" (pick the one or two most recent touches, not a list).
        - Voicemails were already left: don't repeat them. New angle and new wording, and it can be shorter and lighter.
        The TEXT, LINKEDIN and LINKEDIN MESSAGE lines below follow the same history: e.g. the text can say
        "left you a voicemail" or "sent you a note on LinkedIn" when that's true.
        No pitch, no hype, no email.
        CUE: one short delivery tip. STAGE: Voicemail.
        Then add three more lines:
        TEXT: <the text message to send right after. Under 40 words. Sounds like a real person texting, not marketing,
        and like the voicemail above. The rep introduces themselves the same way as in the voicemail, then the same
        reason for reaching out (the campaign's angle, tied to their role or company),
        then one easy yes/no question about THEIR situation (e.g. "Is that still a headache for your team?"),
        then one short line saying what happens next, so they know they'll hear from the rep again. Make it true to
        the history: calls left = "I'll try you again tomorrow if I don't hear back." or "I'll send you a note on
        LinkedIn too."; last call = "I won't keep calling. Reach out anytime." Vary the wording each time.>
        LINKEDIN: <a LinkedIn connection request note. Under 200 characters. Same voice and intro as the voicemail.
        Says the rep just tried calling, gives the same reason, no pitch, no links, no emojis.>
        LINKEDIN MESSAGE: <a LinkedIn direct message, for when they're already connected. Under 400 characters.
        Same voice and intro as the voicemail. Says the rep just tried calling, gives the same reason, one easy
        question. No links, no emojis.>
        Rules for the voicemail, TEXT and both LinkedIn lines:
        - Never name anyone they haven't met (no "Oliver", no "my partner", no "our team lead"). They only know the rep.
        - Don't ask for a meeting, a call length or a day in a first touch. Ask about their situation instead.
          Only after earlier texts or voicemails (see the history) can a later one offer a short call, and then as
          a simple question ("Worth a quick chat?"), still without naming anyone else.
        - One idea per message. No jargon, no "quick look at yours", no hype.
        Never copy wording from these instructions; the words come from the campaign.
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
    /// What the 21-day plan says to send today.
    var textDue = false
    var linkedInDue = false
    var linkedInMessageFirst = false // the last call day: a message, not a connection note

    /// Everything due today is done.
    /// Connect day: both the note and the message. Last call day: the message.
    var allDone: Bool {
        (textDone || !textDue)
            && (!linkedInDue || (linkedInMessageFirst ? linkedinMessageDone : linkedinDone && linkedinMessageDone))
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
    /// The record whose status is being saved right now (nil = not saving).
    @Published private(set) var savingStatusFor: String?
    /// "Saving..." only for the person on screen.
    var savingStatus: Bool { savingStatusFor != nil && savingStatusFor == statusRecordID }
    @Published var statusMessage: String?

    /// "Contact" or "Lead" for the record on screen.
    var statusObject: String? { statusRecordID.flatMap(Salesforce.objectFor) }

    /// Notices which Contact or Lead is on screen and loads its status.
    func refreshRelationship() {
        let id: String? = leads.isActive ? leads.details?.id : SalesforceChrome.url().flatMap(CallList.recordID)
        let usable = id.flatMap { Salesforce.objectFor(id: $0) == nil ? nil : $0 }
        // No record on screen (LinkedIn opened, a list page, Chrome busy): keep the last person.
        // Only a different person's record switches the status card.
        guard usable != nil, usable != statusRecordID else { return }
        statusRecordID = usable
        recordStatus = nil
        statusMessage = nil
        guard let usable else { return }
        if RemovedList.contains(usable) || DialHistory.isMaxed(usable) { skipRemoved(usable); return }
        guard Salesforce.isConnected else { return }
        Task { [weak self] in
            // Only act on a real answer from Salesforce (an error is not "blank").
            let loaded: String?
            do { loaded = try await Salesforce.status(of: usable) } catch { return }
            guard let self, self.statusRecordID == usable else { return }
            let value = loaded?.trimmingCharacters(in: .whitespaces)
            if (value ?? "").isEmpty {
                // A Contact with no Relationship Status yet: set it to No Relationship.
                if Salesforce.objectFor(id: usable) == "Contact" {
                    self.recordStatus = "No Relationship"
                    do {
                        try await Salesforce.setStatus(of: usable, to: "No Relationship")
                        ActivityLog.add("Status: blank, saved No Relationship for \(self.calling ?? usable)")
                    } catch {
                        if self.statusRecordID == usable { self.recordStatus = nil }
                        ActivityLog.problem("Couldn't set No Relationship: \(error.localizedDescription)")
                    }
                }
                return
            }
            self.recordStatus = value
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
    func saveStatus(_ value: String, unqualifiedReason: String? = nil) {
        guard let id = statusRecordID, !savingStatus else { return }
        guard Salesforce.isConnected else {
            statusMessage = "Sign in to Salesforce first: gear menu > Setup > Salesforce."
            return
        }
        savingStatusFor = id
        statusMessage = nil
        ActivityLog.add("Status: saving \(value) for \(calling ?? id)")
        Task { [weak self] in
            do {
                // Never hang: give up after 15 seconds.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await Salesforce.setStatus(of: id, to: value, unqualifiedReason: unqualifiedReason) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw Salesforce.SFError(message: "Salesforce didn't answer in 15 seconds. Try Save again.")
                    }
                    try await group.next()
                    group.cancelAll()
                }
                guard let self else { return }
                if self.savingStatusFor == id { self.savingStatusFor = nil }
                ActivityLog.add("Status: saved \(value)")
                // Taken off the list even if the rep already moved on.
                if Salesforce.removedStatuses.contains(value) { RemovedList.add(id) } else { RemovedList.remove(id) }
                guard self.statusRecordID == id else { self.callList.refreshUpNext(); return }
                self.recordStatus = value
                if Salesforce.removedStatuses.contains(value) {
                    RemovedList.add(id)
                    self.statusMessage = "Saved. Taken off your list."
                    // Between calls: on to the next person right away (and call them, if auto-dial is on).
                    // During a call: the app moves on by itself when the call ends (see endCall).
                    if self.status == .ready {
                        if self.autoNextTask != nil, self.currentAttemptKey.map({ $0.prefix(15) == id.prefix(15) }) == true {
                            // The redial countdown was running for them: stop it and go to the next person.
                            ActivityLog.add("Redial cancelled: marked \(value)")
                            self.startNextSequence()
                        } else if self.openingID == nil, self.autoNextIn == nil {
                            // Still getting their call ready: stop that, they're off the list.
                            self.readyTask?.cancel()
                            self.gettingReady = nil
                            self.gettingReadyDetail = nil
                            ActivityLog.add("Marked \(value): on to the next person")
                            self.waitingForText = false
                            self.startNextSequence()
                        }
                    }
                } else {
                    RemovedList.remove(id)
                    self.statusMessage = "Saved."
                }
                self.callList.refreshUpNext()
            } catch {
                ActivityLog.problem("Status: save failed: \(error.localizedDescription)")
                guard let self else { return }
                if self.savingStatusFor == id { self.savingStatusFor = nil }
                if self.statusRecordID == id { self.statusMessage = error.localizedDescription }
            }
        }
    }

    /// Points the coach at the lead on screen: name, details, opener, voicemail.
    func applyLead() {
        guard let d = leads.details else { return }
        problem = nil
        if d.id != currentAttemptKey { currentAttemptKey = nil; lastCallAnswered = true }
        appliedLeadID = d.id
        calling = "\(d.object) \"\(d.name)\""
        recordDetails = d.promptText
        prepareOpener()
        prepareVoicemail()
        startFollowUp()
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
                if self.status == .ready { self.pendingDialSince = Date() } // the call may already be live
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
        if openNextInChrome() {
            if dialNow { dialFromSalesforcePage(expecting: callList.lastOpenedID) }
            return
        }
        // Ran out of people the app can see: scroll the Salesforce list to load more, then try again.
        Task { [weak self] in
            guard let self else { return }
            self.gettingReady = "Loading more people..."
            let more = await self.callList.loadMore()
            self.gettingReady = nil
            ActivityLog.add("Next: loaded more rows from the list (\(more ? "found more" : "none"))")
            if more, self.openNextInChrome(), dialNow {
                self.dialFromSalesforcePage(expecting: self.callList.lastOpenedID)
            } else if !more {
                self.listDone = true // the banner offers the next campaign's list
                ActivityLog.add("List done for today: \(self.campaign.name)")
            }
        }
    }

    /// Opens the next person in the Salesforce tab and points the coach at them right away.
    private func openNextInChrome() -> Bool {
        problem = nil
        guard callList.openNext() else {
            ActivityLog.add("Next: couldn't open the next person (\(callList.message ?? "no reason"))")
            return false
        }
        callMessage = nil
        listDone = false
        let upcoming = callList.records.first { $0.id == callList.lastOpenedID }?.name
        // Show their opener now, before the page loads and before the phone rings.
        let kind = callList.lastOpenedID.map { $0.hasPrefix("003") ? "Contact" : "Lead" } ?? "Lead"
        calling = upcoming.map { "\(kind) \"\($0)\"" }
        openingID = callList.lastOpenedID
        openingSince = Date()
        ActivityLog.add("Next: opened \(calling ?? "?")")
        recordDetails = nil
        detailsTried = false
        personalOpenerFor = nil
        prepareOpener()
        detailsPending = true // read their page once it loads, for a more personal line
        tabTicks = 1  // read the page on the very next tick
        return true
    }

    // MARK: Moving on after a call: send the text, load the next person, count down, dial

    /// The "Double tap" switch next to Auto-dial: on = call each lead twice (redial), off = once.
    var doubleTap: Bool {
        get { UserDefaults.standard.object(forKey: "doubleTap") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "doubleTap"); objectWillChange.send() }
    }
    /// Dials per lead per visit: 2 with Double tap, otherwise 1.
    var maxAttempts: Int { doubleTap ? 2 : 1 }

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
        guard openNextInChrome() else {
            nextLead(dial: autoDial) // loads more of the list, or says the list is done
            return
        }
        if autoDial { dialFromSalesforcePage(expecting: callList.lastOpenedID, countdown: 3) }
    }

    // MARK: Double dial

    /// Calls per lead today, and whether the last call reached a person.
    private var attempts: [String: Int] = [:]
    @Published private(set) var currentAttemptKey: String?
    @Published private(set) var lastCallAnswered = true
    var currentAttempts: Int { currentAttemptKey.flatMap { attempts[$0] } ?? 0 }

    /// After a first try nobody answered (or voicemail), offer to call right back.
    var shouldOfferRedial: Bool {
        status == .ready && currentAttemptKey != nil && !lastCallAnswered && currentAttempts < maxAttempts
            && !(currentAttemptKey.map(DialHistory.isMaxed) ?? false) // last try: no redial
            && !(currentAttemptKey.map(RemovedList.contains) ?? false) // marked Not Quality Prospect / Negative: no redial
    }

    /// Who the current lead is, for counting tries.
    private func recordKey() -> String? {
        if leads.isActive { return leads.details?.id }
        return SalesforceChrome.url().flatMap(CallList.recordID) ?? calling
    }

    /// Calls the same person again right away.
    func redial() {
        guard status == .ready, let key = currentAttemptKey, !RemovedList.contains(key) else { return }
        cancelAutoNext()
        if leads.isActive {
            dial()
        } else if !dialing, !callFromPage() {
            problem = "No phone number on this Salesforce page. Click Next."
        }
    }

    /// The Call button for the lead open in Salesforce.
    func callOpenLead() {
        cancelAutoNext()
        guard status == .ready, !dialing, gettingReady == nil else { return } // busy, not a missing number
        callMessage = nil
        gettingReady = "Getting ready..."
        ActivityLog.add("Call button: \(calling ?? "no record")")
        callWhenReady { [weak self] in self?.callMessage = "No phone number on this Salesforce page. Click Next." }
    }

    /// Everything on screen is for the person open in Salesforce: name, page details,
    /// voicemail and follow-ups (written from their page), and Claude's opener for them.
    private func readyToDial(waited: TimeInterval) -> Bool {
        guard let calling, SalesforceTab.currentRecord() == calling else { return false }
        let detailsOK = detailsTried
        let voicemailOK = voicemailScript != nil && voicemailFor == calling
            && (voicemailUsedDetails || recordDetails == nil || waited > 8)
        // Claude's personal opener; after 10 seconds the instant one (already for them) is enough.
        let openerOK = personalOpenerFor == calling || waited > 10
        return detailsOK && voicemailOK && openerOK
    }

    /// The one thing the app is still waiting for, in a few words (for the Call button).
    private func waitingFor() -> String {
        guard let calling else { return "an open Salesforce record" }
        if SalesforceTab.currentRecord() != calling { return "the Salesforce page" }
        if !detailsTried { return "their page details" }
        if !(voicemailScript != nil && voicemailFor == calling) { return "their voicemail" }
        return "their opener"
    }
    private var lastWaitingFor = ""

    /// What's still missing, in plain words, when the app won't dial.
    private func readinessGap() -> String {
        guard let calling else { return "no Salesforce record is open in Chrome" }
        if SalesforceTab.currentRecord() != calling { return "the Salesforce page doesn't match \(Screener.firstName(calling) ?? "this person")" }
        if !detailsTried { return "couldn't read their Salesforce page" }
        if !(voicemailScript != nil && voicemailFor == calling) {
            return "their voicemail and follow-ups weren't written" + (lastVoicemailError.map { " (Claude said: \($0))" } ?? "")
        }
        return "their opener wasn't ready"
    }

    /// Dials only once the script and follow-ups are for this exact person. Gives up after 25 s.
    private func callWhenReady(countdown: Int = 0, onFail: @escaping () -> Void = {}) {
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            let start = Date()
            while let self, !Task.isCancelled, self.status == .ready {
                self.syncRecord()
                let waited = Date().timeIntervalSince(start)
                // No voicemail for this person and nothing writing one: try again.
                let haveVoicemail = self.voicemailScript != nil && self.voicemailFor == self.calling
                if !haveVoicemail, self.voicemailTask == nil, self.calling != nil, self.detailsTried || waited > 4,
                   Date().timeIntervalSince(self.lastVoicemailTry) > 3 { self.prepareVoicemail() }
                // Claude still hasn't written it: use the ready-made one with their name.
                if !haveVoicemail, waited > 12, let who = self.calling {
                    self.voicemailTask?.cancel()
                    self.voicemailTask = nil
                    self.voicemailScript = self.instantVoicemail(for: who)
                    self.voicemailFor = who
                    self.voicemailKey = self.recordKey()
                    self.voicemailUsedDetails = true
                    ActivityLog.problem("Used the ready-made voicemail for \(who). Claude: \(self.lastVoicemailError ?? "no answer in 12 s")")
                }
                if self.readyToDial(waited: waited) {
                    self.gettingReady = nil
                    self.gettingReadyDetail = nil
                    self.lastWaitingFor = ""
                    ActivityLog.add("Gate: ready for \(self.calling ?? "?") after \(Int(waited)) s")
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
                            self.callMessage = "The Salesforce page changed during the countdown. Click Call when ready."
                            return
                        }
                    }
                    if !self.callFromPage() { onFail() }
                    return
                }
                if waited > 25 {
                    self.gettingReady = nil
                    self.gettingReadyDetail = nil
                    self.callMessage = "Didn't call: \(self.readinessGap()). Click Call to try again."
                    ActivityLog.problem("Gate: gave up after 25 s. \(self.readinessGap())")
                    self.lastWaitingFor = ""
                    return
                }
                let name = Screener.firstName(self.calling) ?? "the next person"
                let missing = self.waitingFor()
                self.gettingReady = "Getting ready..."
                self.gettingReadyDetail = "Getting \(name) ready: waiting for \(missing)."
                if missing != self.lastWaitingFor {
                    self.lastWaitingFor = missing
                    ActivityLog.add("Gate: \(self.calling ?? "nobody") waiting for \(missing) (page shows \(SalesforceTab.currentRecord() ?? "nothing"))")
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.gettingReady = nil
            self?.gettingReadyDetail = nil
        }
    }

    /// Calls the Mobile number on the open Salesforce page (or Phone, if there's no Mobile), right
    /// from the app (through Aircall). Only if Aircall calling isn't set up does it click the number
    /// in Salesforce. Returns false when the page has neither.
    @discardableResult
    func callFromPage() -> Bool {
        guard status == .ready, !dialing else { return false }
        syncRecord() // make sure the script and voicemail are for this person
        // The Aircall phone inside the coach (or the desktop app): dial through the API.
        if AircallPhone.isOn || Aircall.canPlaceCalls {
            guard let mobile = SalesforceChrome.dialNumber() else {
                ActivityLog.add("Dial: no Mobile or Phone found on the page for \(calling ?? "?")")
                return false
            }
            ActivityLog.add("Dial: \(calling ?? "?") at \(mobile)")
            dialing = true
            dialError = nil
            Task { [weak self] in
                do {
                    try await Aircall.startCall(to: mobile)
                    guard let self else { return }
                    self.dialing = false
                    self.callList.markCurrentCalled()
                    if self.status == .ready { self.pendingDialSince = Date() } // the call may already be live
                } catch {
                    self?.dialing = false
                    self?.callMessage = "Aircall didn't start the call: \(error.localizedDescription)"
                    ActivityLog.problem("Dial failed: \(error.localizedDescription)")
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
        readyTask?.cancel()
        // Kept in readyTask, so Wait, Next and Call cancel it like everything else.
        readyTask = Task { [weak self] in
            var pageOpened = id == nil
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.status == .ready else { return }
                if let id, SalesforceChrome.url().flatMap(CallList.recordID) != id { continue } // not loaded yet
                pageOpened = true
                if SalesforceChrome.dialNumber() != nil {
                    // Page loaded and has a Mobile or Phone: dial once their script and follow-ups are ready.
                    self.noMobileSkips = 0
                    self.callWhenReady(countdown: countdown) { [weak self] in self?.callMessage = "No phone number on this Salesforce page. Click Next." }
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            guard pageOpened else {
                // The page never opened: don't skip anyone, just say so.
                self.callMessage = "Their Salesforce page didn't open. Click Call when it's showing."
                ActivityLog.problem("Next: page for \(id ?? "?") didn't open in 8 s")
                return
            }
            // No Mobile or Phone: nothing to call. Skip to the next person (up to 20 in a row).
            ActivityLog.add("Next: no Mobile or Phone for \(self.calling ?? "?"), skipping")
            self.noMobileSkips += 1
            if self.noMobileSkips <= 20 {
                self.problem = "No phone number. Skipped to the next person."
                self.nextLead()
            } else {
                self.noMobileSkips = 0
                self.problem = "20 people in a row had no phone number. Check the Mobile and Phone fields are on the Salesforce page."
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
        touchpoints.currentCampaign = next.name
        guard next != campaign else { return }
        campaign = next
        touchpoints.currentCampaign = next.name
        listDone = false
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
        BugReporter.context = { [weak self] in self?.debugSummary() ?? "" }
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
    private var lastSyncedKey: String?

    private func syncRecord() {
        guard !leads.isActive else { return }
        // Just opened someone: ignore the old page until theirs shows, so nothing flips back.
        // (The address changes before the tab title does, so also wait for the title, up to 3 s.)
        if let waitingFor = openingID {
            let age = Date().timeIntervalSince(openingSince)
            // Wait for their page (up to 6 s), then for the title (up to 3 s). Never longer.
            if age < 6, SalesforceChrome.url().flatMap(CallList.recordID).map({ $0.prefix(15) }) != waitingFor.prefix(15) { return }
            if age < 3, SalesforceTab.currentRecord() != calling { return }
            openingID = nil
        }
        let record = SalesforceTab.currentRecord()
        refreshRelationship()
        // Nothing on screen (LinkedIn opened, a list page): keep everything for the last person,
        // so the status, LinkedIn and text cards stay up. Only a different person switches them.
        guard record != nil else { return }
        // Two leads can share a name ("Unknown Unknown"): a different Salesforce record ID is a new person too.
        let pageKey = recordKey()
        guard record != calling || detailsPending || pageKey != lastSyncedKey else { return }
        lastSyncedKey = pageKey
        if record != calling {
            ActivityLog.add("Record on screen: \(record ?? "none") (was \(calling ?? "none"))")
            callMessage = nil // a new person: the last person's message no longer applies
        }
        detailsPending = false
        calling = record
        if recordKey() != currentAttemptKey { currentAttemptKey = nil; lastCallAnswered = true }
        recordDetails = nil
        detailsTried = false
        personalOpenerFor = nil
        prepareOpener()
        // The voicemail is written once, after their page is read (below), not twice.
        voicemailTask?.cancel()
        voicemailTask = nil
        voicemailScript = nil
        // Their text and LinkedIn card is always up while their record is open.
        startFollowUp()
        // Salesforce fills in the page after the title changes: read the details a moment later.
        detailsTask?.cancel()
        let pageID = SalesforceChrome.url().flatMap(CallList.recordID)
        detailsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.calling == record, record != nil,
                  SalesforceChrome.url().flatMap(CallList.recordID) == pageID else { return }
            self.recordDetails = SalesforceTab.pageText()
            self.detailsTried = true
            // Fill in the card's phone and LinkedIn link now that the page is loaded.
            if var f = self.followUp, f.key == self.recordKey() {
                if Salesforce.isPlaceholderName(f.prospect ?? ""), let company = self.recordCompany, !company.isEmpty { f.prospect = company }
                if f.phone.isEmpty { f.phone = Aircall.phone(in: self.recordDetails) ?? SalesforceChrome.mobileNumber() ?? "" }
                if f.linkedinURL == nil { f.linkedinURL = Self.linkedInProfile(details: self.recordDetails) }
                self.followUp = f
                self.applyPlan()
            }
            ActivityLog.add("Page details for \(record ?? "?"): \(self.recordDetails == nil ? "couldn't read (Chrome setting?)" : "read")")
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
                if openingID == nil { callList.refreshUpNext() }
                if let m = callMessage, m.hasPrefix("Everyone on this Salesforce list"), case .ready = callList.state {
                    callMessage = nil
                }
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
            // Safety net: nobody has said a word for 90 s = the call is over (no real call is that quiet).
            let silentFor = Date().timeIntervalSince(lastWordsAt ?? callStartedAt)
            if silentFor > 90, !startedByHand {
                ActivityLog.problem("Call ended: 90 s with no words")
                endCall(); return
            }
            // Only count quiet after the call's audio has shown up once, so a call that's
            // still ringing (we start listening right after dialing) isn't ended early.
            if !startedByHand, heardCallAudio || Date().timeIntervalSince(callStartedAt) > 45 {
                quietTicks = onCall ? 0 : quietTicks + 1
                if quietTicks >= 6 { endCall(); return } // Chrome let go of the call for 3 seconds
            }
            checkAircallEveryFewSeconds()
            if aircallTicks % 2 == 0, Date().timeIntervalSince(callStartedAt) < 30 { followCallAudio() }
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
        let hadVoicemail = sawVoicemail // for the log
        if hadVoicemail, !(currentAttempts < maxAttempts && autoDial), let key = currentAttemptKey,
           Cadence.step(for: key)?.leaveVoicemail ?? true,
           let said = voicemailScript?.say, voicemailFor == calling {
            DialHistory.logVoicemail(key, body: said)
        }
        // Didn't connect: over in under 12 seconds, nobody talked, no voicemail. That's a bad
        // number's beeping tone or a dropped call, not a person who didn't pick up (that rings 20+ s).
        let quickFail = !badNumberThisCall && !startedByHand && !sawVoicemail
            && Date().timeIntervalSince(callStartedAt) < 12
            && !turns.contains { $0.speaker == .prospect }
        ActivityLog.add("Call ended: \(calling ?? "?") after \(Int(Date().timeIntervalSince(callStartedAt))) s. voicemail=\(sawVoicemail) theySpoke=\(turns.contains(where: { $0.speaker == .prospect })) bad=\(badNumberThisCall)")
        if quickFail, let key = currentAttemptKey {
            let fails = DialHistory.logFailedConnect(key)
            if fails >= 2 { markNotQualityProspect(key, reason: "didn't connect twice") }
            nextCall()
            waitingForNewCall = true
            endedAt = Date()
            followUp = nil
            lastCallAnswered = true // no redial
            problem = fails >= 2 ? "Didn't connect again. Bad number: taken off your list." : "Didn't connect (bad number or network). Moving on."
            afterHangUp { [weak self] in self?.startNextSequence() }
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
            problem = phoneTreeThisCall ? "Phone tree. Disqualified and taken off your list." : "Bad number. Taken off your list."
            afterHangUp { [weak self] in self?.startNextSequence() }
            return
        }
        // 2nd try went to voicemail: they've had both calls. Move on by itself.
        let moveOn = sawVoicemail && currentAttempts >= maxAttempts
        nextCall()
        waitingForNewCall = true
        endedAt = Date()
        // Didn't reach them (no answer or voicemail): the text and LinkedIn card shows after
        // every such call, even when the voicemail greeting wasn't caught.
        if !lastCallAnswered, followUp == nil || followUp?.key != currentAttemptKey {
            startFollowUp()
            ActivityLog.add("Follow-up card for \(calling ?? "?") (voicemail heard: \(hadVoicemail))")
        }
        if let key = currentAttemptKey, RemovedList.contains(key) {
            // Marked Unqualified (or Not Quality Prospect / Negative) during the call: no text, no redial.
            ActivityLog.add("Call ended for someone taken off the list: on to the next person")
            followUp = nil
            waitingForText = false
            afterHangUp { [weak self] in self?.startNextSequence() }
        } else if shouldOfferRedial, autoDial {
            // 1st try, no answer: "Calling Jane Doe again in 3", then redial the same person.
            startAutoRedial()
        } else if !shouldOfferRedial, !lastCallAnswered, let f = followUp {
            // Done with them for now: send the text, then the next call starts.
            if f.textDone || !f.textDue { afterHangUp { [weak self] in self?.startNextSequence() } } else { waitingForText = true }
        } else if moveOn {
            afterHangUp { [weak self] in self?.startNextSequence() }
        }
    }

    /// 1st try reached a recording (100% sure: words only a machine says) and auto-dial is on:
    /// click Aircall's hang-up button, wait until Aircall says the line is free, then redial in 1 s.
    /// If anything is off (no button, line still busy), it does nothing and the rep hangs up as usual.
    private func autoHangUpForRedial() {
        guard autoDial, AircallPhone.isOn, currentAttempts < maxAttempts, !autoHangingUp, !autoHungUpThisCall,
              !phoneTreeActive, !phoneTreeThisCall, // never hang up on a phone menu
              let key = currentAttemptKey, !DialHistory.isMaxed(key), !RemovedList.contains(key) else { return }
        autoHangingUp = true
        autoHungUpThisCall = true
        ActivityLog.add("Recording for sure on the 1st try for \(calling ?? "?"): hanging up to redial")
        Task { [weak self] in
            guard let self, self.status == .live else { self?.autoHangingUp = false; return }
            var done = await AircallPhone.shared.hangUp()
            if done {
                // Only end the call on our side once Aircall says the line is free (up to 5 s).
                done = false
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    if await Aircall.lineIsOnCall() == false { done = true; break }
                }
            }
            self.autoHangingUp = false
            guard self.status == .live else { return }
            if done {
                self.redialRightAway = true
                self.endCall()
            } else {
                ActivityLog.problem("Auto hang-up didn't finish: the rep hangs up, redial as usual")
            }
        }
    }
    private var autoHangingUp = false
    private var autoHungUpThisCall = false
    /// The app hung up a 1st-try recording: redial after 1 second instead of 3.
    private var redialRightAway = false

    /// Counts down 3 seconds (1 after an automatic hang-up), then calls the same person again. Wait stops it.
    private func startAutoRedial() {
        autoNextTask?.cancel()
        autoNextName = calling.flatMap { c in
            c.firstIndex(of: "\"").map { String(c[c.index(after: $0)...]).replacingOccurrences(of: "\"", with: "") }
        }.map { "\($0) again" }
        let countdown = redialRightAway ? 1 : 3
        redialRightAway = false
        autoNextTask = Task { [weak self] in
            for left in stride(from: countdown, through: 1, by: -1) {
                self?.autoNextIn = left
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.status != .ready { self.cancelAutoNext(); return }
            }
            guard let self, !Task.isCancelled, self.shouldOfferRedial else { return }
            self.autoNextIn = nil
            self.redial()
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
            for left in stride(from: 3, through: 1, by: -1) {
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
        hangUpGen += 1
        waitingForText = false
        autoNextName = nil
        readyTask?.cancel()
        gettingReady = nil
        gettingReadyDetail = nil
        autoNextTask?.cancel()
        autoNextTask = nil
        autoNextIn = nil
    }
    private var endedAt = Date.distantPast

    /// After a call ends while Chrome still holds the mic, don't treat that as a new call.
    private var waitingForNewCall = false
    private var callStartedAt = Date.distantPast
    private var heardCallAudio = false
    private var retargets = 0

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
    private var aircallSawCall = false
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
            if onCall { self.aircallSawCall = true }
            // Trust Aircall's "no call" once it has listed this call, or after 20 s if it never
            // lists it (some setups don't). But never while people are still talking.
            let age = Date().timeIntervalSince(self.callStartedAt)
            let talking = self.lastWordsAt.map { Date().timeIntervalSince($0) < 8 } ?? false
            guard self.aircallSawCall || age > 20, !talking else { self.aircallSaysOver = 0; return }
            self.aircallSaysOver = onCall ? 0 : self.aircallSaysOver + 1
            if self.aircallSaysOver >= 2 {
                ActivityLog.add("Aircall says the call is over")
                self.endCall()
            }
        }
    }

    func startByHand() {
        waitingForNewCall = false
        startedByHand = true
        startCall()
    }

    private func startCall() {
        problem = nil
        redialRightAway = false
        autoHungUpThisCall = false
        phoneTreeThisCall = false
        phoneTreeActive = false
        phoneTreeTask?.cancel()
        keysMessage = nil
        guard startAudio() else { return }
        if !leads.isActive { callList.markCurrentCalled() } // so Next skips them today (Chrome list)
        if let key = recordKey() {
            currentAttemptKey = key
            attempts[key, default: 0] += 1
        }
        touchpoints.log(.dial)
        callMessage = nil
        pendingDialSince = nil // this dial is now the live call
        ActivityLog.add("Call started: \(calling ?? "?") (try \(currentAttempts))")
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
        retargets = 0
        aircallSaysOver = 0
        aircallSawCall = false
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
        if let key = currentAttemptKey {
            DialHistory.logPickup(key)
            // A real person answered: check "Picked Up Cold Call" in Salesforce.
            if Salesforce.isConnected {
                let who = calling ?? key
                Task {
                    do {
                        try await Salesforce.markPickedUp(key)
                        ActivityLog.add("Picked Up Cold Call checked for \(who)")
                    } catch {
                        ActivityLog.problem("Couldn't check Picked Up Cold Call: \(error.localizedDescription)")
                    }
                }
            }
        }
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
            // The call is over: the voicemail (or any mid-call line) goes away and a fresh
            // "when they pick up" opener shows right away, ready for the redial.
            prepareOpener()
            // Read Chrome a moment later, not while Aircall plays the hang-up tone.
            afterHangUp { [weak self] in self?.syncRecord() } // same person: keep their ready voicemail
        }
    }

    /// Runs work 2 seconds after a call ends. Doing it all at the hang-up moment
    /// (Chrome reads, saving, loading the next person) makes Aircall's hang-up tone skip.
    private func afterHangUp(_ work: @escaping () -> Void) {
        let gen = hangUpGen
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // Skip it if the rep already moved on by hand (Next, Redial, Call).
            guard let self, self.status == .ready, self.hangUpGen == gen else { return }
            work()
        }
    }
    private var hangUpGen = 0

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
            problem = "Add your Deepgram key: gear > Setup > AI keys."
            return false
        }
        streams.set(rep: openStream(.rep, key: deepgramKey), prospect: openStream(.prospect, key: deepgramKey))

        // The Aircall phone inside the coach hands over the call audio itself: no Core Audio tap,
        // so nothing glitches (like the hang-up tone). If it doesn't within 4 s, use the tap.
        if AircallPhone.isOn {
            let streams = self.streams
            let phone = AircallPhone.shared
            phone.onAudio = { isRep, pcm in streams.send(pcm, isRep: isRep) }
            directAudio = true
            ActivityLog.add("Listening straight from the Aircall phone")
            let startedAt = Date()
            directCheck?.cancel()
            directCheck = Task { [weak self] in
                // Check at 4 s and again at 8 s: the other side must have real sound by then
                // (ringback or a voicemail greeting), or the phone isn't sharing the call: use the tap.
                for checkAt in [4.0, 8.0] {
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
                    if phone.lastRemoteAudio > startedAt { break }
                    if checkAt < 8 { continue }
                    phone.onAudio = nil
                    self.directAudio = false
                    ActivityLog.problem("No sound from the Aircall phone after 8 s; using the audio tap")
                    if !self.startTap() { self.stopAudio() }
                    return
                }
                guard let self, !Task.isCancelled, self.status == .live, self.directAudio else { return }
                if phone.lastLocalAudio < startedAt {
                    // The other side comes through, the rep's mic doesn't: add the Mac's mic.
                    phone.onAudio = { isRep, pcm in if !isRep { streams.send(pcm, isRep: false) } }
                    do {
                        try self.capture.startMicOnly { isRep, speech in
                            guard let samples = speech.int16ChannelData?[0] else { return }
                            streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: true)
                        }
                        ActivityLog.add("Rep's side: Mac mic (the phone didn't share it)")
                    } catch {
                        ActivityLog.problem("Mic failed: \(error.localizedDescription)")
                    }
                } else {
                    ActivityLog.add("Hearing both sides straight from the Aircall phone")
                }
            }
            return true
        }
        return startTap()
    }

    private var directAudio = false
    private var directCheck: Task<Void, Never>?

    /// The old way: a Core Audio tap on the call app's sound, plus the mic.
    private func startTap() -> Bool {
        let chrome = AudioProcess.callAudioTargets(in: AudioProcess.others())
        guard !chrome.isEmpty else {
            callMessage = "Can't hear the call yet. Open the Aircall app (or Aircall in Chrome) and start the call."
            ActivityLog.problem("Listening failed: no Aircall or Chrome audio found")
            return false
        }
        do {
            let streams = self.streams
            try capture.start(processes: chrome) { isRep, speech in
                guard let samples = speech.int16ChannelData?[0] else { return }
                streams.send(Data(bytes: samples, count: Int(speech.frameLength) * 2), isRep: isRep)
            }
            ActivityLog.add("Listening to: \(Self.names(of: chrome))")
            return true
        } catch {
            streams.closeAll()
            callMessage = "The coach couldn't start listening: \(error.localizedDescription). The call still works; coaching is off for it."
            ActivityLog.problem("Listening failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Stops listening. Transcription stops right away, but the audio tap is removed a few
    /// seconds later: tearing it down while Aircall plays the hang-up tone makes that tone
    /// stutter and repeat.
    private static func names(of ids: [AudioObjectID]) -> String {
        let all = AudioProcess.others()
        let names = ids.compactMap { id in all.first { $0.id == id }?.name }
        return names.isEmpty ? "\(ids.count) process(es)" : Set(names).sorted().joined(separator: ", ")
    }

    /// Listening starts a second after dialing, sometimes before Aircall's call audio exists.
    /// Once Aircall is clearly on the call, make sure that's what the app listens to.
    private func followCallAudio() {
        guard !directAudio else { return } // the phone hands over its audio itself
        let processes = AudioProcess.others()
        guard AudioProcess.aircallAppOnCall(in: processes) || AudioProcess.chromeOnCall(in: processes) else { return }
        let targets = AudioProcess.callAudioTargets(in: processes)
        // Only add missing call audio (never drop what's working), and at most twice a call.
        guard retargets < 2, !targets.isEmpty, !Set(targets).isSubset(of: Set(capture.tapTargets)) else { return }
        retargets += 1
        do {
            try capture.retargetTap(processes: targets)
            ActivityLog.add("Switched listening to: \(Self.names(of: targets))")
        } catch {
            ActivityLog.add("Couldn't switch listening: \(error.localizedDescription)")
        }
    }

    private func stopAudio() {
        AircallPhone.shared.onAudio = nil
        directCheck?.cancel()
        directAudio = false
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
    /// The record Id the ready-made voicemail is for (matches the follow-up card's key).
    private var voicemailKey: String?
    private var lastVoicemailError: String?
    private var lastVoicemailTry = Date.distantPast
    /// Who the ready-made voicemail was written for, and whether it used their Salesforce page.
    private var voicemailFor: String?
    private var voicemailUsedDetails = false
    /// The page's details were read (or tried) for the person on screen.
    private var detailsTried = false
    /// Who Claude's personal opener on screen is for.
    private var personalOpenerFor: String?
    private var instantOpenerID = -1
    /// Why a call didn't start. Shown right above the Call button and never wiped by a new line.
    @Published var callMessage: String?
    /// One line about what the app is doing, for bug reports.
    func debugSummary() -> String {
        "status=\(status) person=\(calling ?? "none") page=\(SalesforceTab.currentRecord() ?? "none") " +
        "waitingFor=\(gettingReady == nil ? "-" : waitingFor()) voicemailFor=\(voicemailFor ?? "none") " +
        "followUp=\(followUp?.prospect ?? "none") autoDial=\(autoDial) attempts=\(currentAttempts) " +
        "salesforce=\(Salesforce.isConnected) aircall=\(Aircall.canPlaceCalls)"
    }

    /// Everyone due today on this list has been called: time to switch to the next list.
    @Published var listDone = false

    /// Who the countdown is for.
    @Published private(set) var autoNextName: String?
    /// "Getting Burcin's script ready..." while the app waits to dial.
    @Published private(set) var gettingReady: String?
    /// What the Call button is waiting for, in a sentence (shown above the buttons).
    @Published private(set) var gettingReadyDetail: String?
    private var readyTask: Task<Void, Never>?
    private var detailsPending = false
    /// The record Next just opened, until its page is showing.
    private var openingID: String?
    private var openingSince = Date.distantPast

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
                } else if phoneTreeActive {
                    // In a phone menu: no voicemail card, no auto hang-up. Only a real mailbox ends it.
                    if Voicemail.recordingPrompt(recent) {
                        phoneTreeActive = false
                        phoneTreeTask?.cancel()
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                } else if !badNumberThisCall, !phoneTreeThisCall, repWordsInCall < 5,
                          !Voicemail.recordingPrompt(recent), PhoneTree.detects(prospectSoFar + " " + text) {
                    // Work through it by default. Old behavior (disqualify + hang up) behind a setting.
                    if UserDefaults.standard.bool(forKey: "hangUpPhoneTrees") { markPhoneTree() } else { enterPhoneTree() }
                } else if Voicemail.detects(recent, earlyInCall: early)
                    || (!screenerActive && !Screener.detects(firstWords) && Voicemail.longGreeting(firstWords, earlyInCall: early)) {
                    if !voicemailActive || (Voicemail.mailboxFull(recent) && !mailboxFullShown) {
                        showVoicemail(mailboxFull: Voicemail.mailboxFull(recent))
                    }
                    // Surely a recording, and the rep hasn't started talking: hang up and redial.
                    if Voicemail.certain(recent), repWordsInCall < 3 { autoHangUpForRedial() }
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
    /// A phone menu answered: disqualify (Not Quality Prospect / Unqualified), hang up in the
    /// in-app phone, and move on. No voicemail, text or redial. If the hang-up button can't be
    /// found, the rep hangs up and the next call still starts by itself.
    private func markPhoneTree() {
        badNumberThisCall = true
        phoneTreeThisCall = true
        coachTask?.cancel()
        thinking = false
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey { markNotQualityProspect(key, reason: "phone tree") }
        seq += 1
        show(Suggestion(say: "Phone tree. Hanging up. The next call starts by itself.", cue: "Disqualified: phone menus aren't worth working.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        guard AircallPhone.isOn else { return }
        Task { [weak self] in
            guard let self, self.status == .live else { return }
            guard await AircallPhone.shared.hangUp() else {
                self.show(Suggestion(say: "Phone tree. Hang up. The next call starts by itself.", cue: "Disqualified.",
                                     stage: "Exit", sayComplete: true), id: self.seq, kind: .reply)
                return
            }
            // End on our side once Aircall says the line is free (up to 5 s); otherwise Aircall's own end does it.
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                if await Aircall.lineIsOnCall() == false, self.status == .live { self.endCall(); return }
            }
        }
    }
    private var phoneTreeThisCall = false

    /// In a phone menu right now (until a person answers or a mailbox beep is coming).
    private var phoneTreeActive = false
    private var phoneTreeTask: Task<Void, Never>?

    /// A phone menu answered. Show the quick ways through right away, then have Opus listen to the
    /// whole menu and pick the best route to the owner. No voicemail card while the menu plays.
    private func enterPhoneTree() {
        phoneTreeActive = true
        voicemailActive = false
        sawVoicemail = false
        showPhoneTreeTips()
        askPhoneTree()
    }

    /// Opus 5.5 reads everything the menu has said so far and names the highest-leverage keys to
    /// press to reach the owner. Re-asked each time the menu finishes a sentence (after a short pause,
    /// so a new option isn't missed). If a live person is now talking, it says what to say to them.
    private func askPhoneTree() {
        guard let apiKey = Keychain.read(.anthropic) else { return }
        phoneTreeTask?.cancel()
        let menu = prospectSoFar
        let who = calling
        let user = CoachPrompt.phoneTree(menu: menu, calling: calling, details: recordDetails,
                                         repSaid: turns.filter { $0.speaker == .rep }.map(\.text).joined(separator: " "))
        let system = self.system
        phoneTreeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.phoneTreeActive, self.calling == who else { return }
            self.seq += 1
            let id = self.seq
            self.thinking = true
            var text = ""
            do {
                try await CoachSpeed.best.client(apiKey: apiKey).stream(system: system, user: user) { text = $0 }
            } catch {
                if !Task.isCancelled { ActivityLog.problem("Phone tree advice failed: \(error.localizedDescription)") }
                if self.seq == id { self.thinking = false }
                return
            }
            if self.seq == id { self.thinking = false }
            guard !Task.isCancelled, self.phoneTreeActive, self.calling == who else { return }
            let human = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("HUMAN")
            var s = Suggestion.parse(text)
            guard !s.say.isEmpty else { return }
            s.sayComplete = true
            if human {
                // A person picked up (receptionist or the owner): back to normal coaching.
                self.phoneTreeActive = false
                s.stage = s.stage.isEmpty ? "Gatekeeper" : s.stage
                ActivityLog.add("Phone tree: a person answered for \(who ?? "?")")
            } else {
                s.stage = "Phone tree"
                ActivityLog.add("Phone tree route for \(who ?? "?"): \(s.say)")
            }
            self.show(s, id: id, kind: .reply)
        }
    }

    /// The rep clicked "Press 3": sends those keys into the call (the in-app Aircall phone only).
    @Published private(set) var keysMessage: String?
    func pressKeys(_ keys: String) {
        guard status == .live, !keys.isEmpty else { return }
        keysMessage = "Pressing \(keys)..."
        Task { [weak self] in
            let ok = await AircallPhone.shared.sendDigits(keys)
            guard let self else { return }
            ActivityLog.add("Phone tree: pressed \(keys) (\(ok ? "sent" : "didn't go through"))")
            self.keysMessage = ok ? "Pressed \(keys)." : "Couldn't press keys from the app. Use the Aircall keypad."
        }
    }

    /// A phone menu answered: how to get through to the person. Press 0 for an operator, or dial
    /// by name with the first letters of their last name as keypad digits.
    private func showPhoneTreeTips() {
        phoneTreeThisCall = true
        coachTask?.cancel()
        thinking = false
        let full = calling.flatMap { c -> String? in
            guard let open = c.firstIndex(of: "\""), let close = c.lastIndex(of: "\""), open < close else { return nil }
            return String(c[c.index(after: open)..<close])
        }
        let last = full?.split(separator: " ").last.map(String.init) ?? ""
        let keys: [Character: Character] = Dictionary(uniqueKeysWithValues: Array(zip("abcdefghijklmnopqrstuvwxyz",
                                                                                        "22233344455566677778889999")))
        let digits = String(last.lowercased().compactMap { keys[$0] }.prefix(4))
        let byName = digits.isEmpty ? "" : " Dial by name: \(digits) (\(last.prefix(4)))."
        ActivityLog.add("Phone tree for \(calling ?? "?"): showing how to get through")
        seq += 1
        var tips = Suggestion(say: "Phone tree. Press 0 for the operator.\(byName)",
                              cue: "Listening to the menu for a better route. When a person answers: \"Hi, could you put me through to \(full ?? "them")?\"",
                              stage: "Phone tree", sayComplete: true)
        tips.keys = "0"
        show(tips, id: seq, kind: .reply)
    }

    private func markBadNumber() {
        badNumberThisCall = true
        coachTask?.cancel()
        thinking = false
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey { markNotQualityProspect(key, reason: "carrier says the number can't take calls") }
        seq += 1
        show(Suggestion(say: "Bad number. Hang up. The next call starts by itself.", cue: "The carrier says this number doesn't work.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
    }

    /// Bad number: off the call list for good (in the app), and marked in Salesforce as
    /// Not Quality Prospect (Contacts) or Unqualified (Leads). Nothing is deleted in Salesforce.
    private func markNotQualityProspect(_ id: String, reason: String) {
        DialHistory.markBadNumber(id)
        RemovedList.add(id)
        callList.refreshUpNext()
        guard let object = Salesforce.objectFor(id: id) else { return }
        let value = object == "Lead" ? "Unqualified" : "Not Quality Prospect"
        ActivityLog.add("Off the list (\(reason)): \(calling ?? id), marking \(value)")
        guard Salesforce.isConnected else { return }
        Task { [weak self] in
            do {
                try await Salesforce.setStatus(of: id, to: value, unqualifiedReason: "Non-Responsive",
                                               note: reason == "phone tree" ? "Phone tree" : "Bad number (\(reason))")
                ActivityLog.add("Status: saved \(value) (bad number)")
                if self?.statusRecordID == id { self?.recordStatus = value }
            } catch {
                ActivityLog.problem("Couldn't mark the bad number in Salesforce: \(error.localizedDescription)")
            }
        }
    }

    /// Instant voicemail card: the script written before the call, or "mailbox full, move on".
    private func showVoicemail(mailboxFull: Bool) {
        voicemailActive = true
        sawVoicemail = true
        screenerActive = false
        coachTask?.cancel()
        thinking = false
        specTimer?.cancel()
        holdTask?.cancel()
        pending = nil
        specBasis = nil
        uncoached = ""
        seq += 1
        startFollowUp()
        if mailboxFull {
            mailboxFullShown = true
            show(Suggestion(say: currentAttempts < maxAttempts ? "Mailbox is full. Hang up and click Redial." : "Mailbox is full. Hang up. The next call starts by itself.",
                            cue: "No message possible.",
                            stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
        } else if let step = currentAttemptKey.flatMap(Cadence.step(for:)), !step.leaveVoicemail {
            // Not a voicemail day in the 21-day plan.
            show(Suggestion(say: currentAttempts < maxAttempts ? "No voicemail today. Hang up. The redial starts by itself."
                                                     : "No voicemail today. Hang up and move on.",
                            cue: "The plan leaves one voicemail, on day 1. Today is day \(Cadence.callDays[step.index]).",
                            stage: "Voicemail", sayComplete: true), id: seq, kind: .voicemail)
        } else if var script = voicemailScript, voicemailFor == calling {
            if currentAttempts < maxAttempts {
                script.cue = "1st try: hang up and click Redial. Leave this message on the 2nd try."
            } else if let step = currentAttemptKey.flatMap(Cadence.step(for:)) {
                script.cue = "Day \(step.planDay) voicemail (the only one in the plan). Wait for the beep."
            }
            show(script, id: seq, kind: .voicemail)
        } else {
            // Not written yet: ask now. The beep usually gives a few seconds.
            show(Suggestion(say: "Writing your voicemail...", cue: "Wait for the beep.", stage: "Voicemail", sayComplete: true),
                 id: seq, kind: .voicemail)
            ask(.voicemail, user: CoachPrompt.voicemail(calling: calling, details: recordDetails,
                                                         earlierTexts: recordKey().map(DialHistory.sentTexts) ?? [],
                                                         earlierMessages: recordKey().map(DialHistory.sentLinkedInMessages) ?? [],
                                                         history: recordKey().map(DialHistory.historySummary) ?? ""))
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
                            phone: lead?.textNumber ?? Aircall.phone(in: recordDetails) ?? (leads.isActive ? nil : SalesforceChrome.mobileNumber()) ?? "",
                            linkedinURL: lead?.linkedIn ?? Self.linkedInProfile(details: recordDetails),
                            linkedinMessage: earlier?.linkedinMessage ?? "",
                            linkedinMessageDone: earlier?.linkedinMessageDone ?? key.map(DialHistory.linkedInMessageToday) ?? false)
        if followUp?.textDone == true, earlier == nil { followUp?.textStatus = "Already texted today" }
        applyPlan()
        // The script's own messages show right away, no waiting on Claude.
        if var f = followUp {
            var s = Suggestion()
            applyScriptMessages(&s, for: calling)
            if f.text.isEmpty { f.text = s.textMessage }
            if f.linkedin.isEmpty { f.linkedin = s.linkedin }
            if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
            followUp = f
        }
        if let script = voicemailScript, voicemailFor == calling { fillFollowUp(from: script) }
        else if detailsTried || leads.isActive, voicemailTask == nil || voicemailFor != calling {
            prepareVoicemail() // it fills the card when done (in Chrome mode, only once the page is read)
        }
        watchFollowUp()
    }

    private var followUpThisCall = false
    private var followUpWatchdog: Task<Void, Never>?

    /// The card must never sit on "Writing..." forever (Claude failed, timed out, or answered for
    /// someone else). After 12 s with nothing: ask Claude again. After 20 s: fill the empty boxes
    /// with the ready-made text and notes (with their name). Claude's version replaces them if it
    /// comes in later, as long as nothing was sent yet.
    private func watchFollowUp() {
        followUpWatchdog?.cancel()
        let who = calling
        let key = followUp?.key
        func stillEmpty(_ m: CoachModel) -> Bool {
            guard m.calling == who, let f = m.followUp, f.key == key else { return false }
            return f.text.isEmpty || f.linkedin.isEmpty || f.linkedinMessage.isEmpty
        }
        followUpWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, stillEmpty(self) else { return }
            if self.voicemailTask == nil, self.voicemailScript == nil, self.status == .ready {
                ActivityLog.problem("Follow-ups still writing for \(who ?? "?") after 12 s: asking Claude again")
                self.prepareVoicemail()
            }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, stillEmpty(self), var f = self.followUp else { return }
            let s = self.instantVoicemail(for: who)
            if f.text.isEmpty { f.text = s.textMessage }
            if f.linkedin.isEmpty { f.linkedin = s.linkedin }
            if f.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
            self.followUp = f
            ActivityLog.problem("Used the ready-made text and LinkedIn notes for \(who ?? "?"). Claude: \(self.lastVoicemailError ?? "no answer in 20 s")")
        }
    }

    /// Today's checklist for this person, from the 21-day plan: each step and whether it's done.
    func todaySteps(for key: String?) -> [(title: String, done: Bool)] {
        guard let key else { return [] }
        let p = DialHistory.person(key)
        guard let step = Cadence.step(for: key), p.pickups == 0 else { return [] }
        let dialsToday = p.dials.filter { Calendar.current.isDateInToday($0) }.count
        var steps: [(String, Bool)] = [("2 dials (\(min(dialsToday, 2)) of 2)", dialsToday >= 2)]
        if step.leaveVoicemail {
            steps.append(("Voicemail on the 2nd dial", p.voicemails.contains { Calendar.current.isDateInToday($0) }))
        }
        if step.textToday {
            let wa = followUp.map { Cadence.isWashington($0.phone) } ?? false
            if !wa { steps.append(("Text", DialHistory.textedToday(key))) }
        }
        if step.linkedInConnect {
            steps.append(("LinkedIn request", DialHistory.linkedInToday(key)))
            steps.append(("LinkedIn message", DialHistory.linkedInMessageToday(key)))
        }
        return steps
    }

    /// Today's 21-day plan step decides which follow-ups show: text only on the 2nd call day
    /// (never to Washington numbers), LinkedIn note on the 1st, LinkedIn message on the last.
    private func applyPlan() {
        guard var f = followUp else { return }
        guard let key = f.key else {
            // Don't know who this is: show nothing rather than risk over-contacting.
            f.textDue = false; f.linkedInDue = false; followUp = f; return
        }
        let step = Cadence.step(for: key)
        let washington = Cadence.isWashington(f.phone)
        f.textDue = (step?.textToday ?? false) && !washington
        if washington, step?.textToday == true, !f.textDone { f.textStatus = "No text: Washington number (texts need consent there)." }
        f.linkedInDue = (step?.linkedInConnect ?? false) || (step?.linkedInMessage ?? false)
        f.linkedInMessageFirst = step?.linkedInMessage ?? false
        followUp = f
    }

    /// Fills in the text and LinkedIn note. The rep sends each one with a button.
    /// - Parameter replace: a better version (written from their Salesforce page) replaces
    ///   anything not sent yet.
    private func fillFollowUp(from written: Suggestion, replace: Bool = false) {
        // Only into the card of the person this voicemail was written for.
        guard var f = followUp, f.key == nil || voicemailKey == nil || f.key == voicemailKey else { return }
        var s = written
        applyScriptMessages(&s, for: calling)
        if (f.text.isEmpty || (replace && !f.textDone)), !s.textMessage.isEmpty { f.text = s.textMessage }
        if (f.linkedin.isEmpty || (replace && !f.linkedinDone)), !s.linkedin.isEmpty { f.linkedin = s.linkedin }
        if (f.linkedinMessage.isEmpty || (replace && !f.linkedinMessageDone)), !s.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
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
        if let key = f.key, DialHistory.alreadySent(f.text, to: key) {
            followUp?.textStatus = "You already sent them these exact words. Edit the text, or wait a moment for a new one."
            ActivityLog.add("Text blocked: same words as an earlier text to \(f.prospect ?? "?")")
            return
        }
        followUp?.textStatus = "Sending..."
        Task { [weak self] in
            do {
                try await Aircall.sendText(to: f.phone, body: f.text)
                self?.touchpoints.log(.text)
                if let key = f.key { DialHistory.logText(key, body: f.text) }
                ActivityLog.add("Text sent to \(f.prospect ?? "?") at \(f.phone)")
                // Only mark the card it was sent from (not a newer person's card).
                guard self?.followUp?.key == f.key else { return }
                self?.followUp?.textStatus = "Sent"
                self?.followUp?.textDone = true
            } catch {
                ActivityLog.problem("Text failed: \(error.localizedDescription)")
                guard self?.followUp?.key == f.key else { return }
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
                if let key = f.key { DialHistory.logLinkedInMessage(key, body: f.linkedinMessage) }
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
    var recordCompany: String? {
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
        lastVoicemailTry = Date()
        voicemailFor = forWho
        voicemailKey = recordKey()
        guard let key = Keychain.read(.anthropic) else { return }
        let client = CoachSpeed.fastest.client(apiKey: key) // voicemails always use Haiku: fast
        let system = self.system
        let user = CoachPrompt.voicemail(calling: calling, details: recordDetails,
                                         earlierTexts: recordKey().map(DialHistory.sentTexts) ?? [],
                                         earlierMessages: recordKey().map(DialHistory.sentLinkedInMessages) ?? [],
                                         history: recordKey().map(DialHistory.historySummary) ?? "")
        voicemailTask = Task { [weak self] in
            var text = ""
            do {
                try await client.stream(system: system, user: user) { text = $0 }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    ActivityLog.problem("Voicemail failed for \(forWho ?? "?"): \(error.localizedDescription)")
                    self?.lastVoicemailError = error.localizedDescription
                    // Let the next try (or the voicemail card) write it again.
                    if self?.calling == forWho { self?.voicemailTask = nil; self?.voicemailFor = nil }
                }
                return
            }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            s.stage = "Voicemail"
            self?.applyScriptVoicemail(&s, for: forWho)
            if !Task.isCancelled, !s.say.isEmpty, self?.calling == forWho {
                ActivityLog.add("Voicemail ready for \(forWho ?? "?") (from page: \(usedDetails))")
                self?.voicemailUsedDetails = usedDetails
                self?.voicemailScript = s
                self?.fillFollowUp(from: s, replace: usedDetails) // the card is always up for the person on screen
            }
            if !Task.isCancelled { self?.voicemailTask = nil }
        }
    }

    /// Instant line for a call screener. No Claude call, no waiting.
    private func showScreenerLine() {
        screenerActive = true
        coachTask?.cancel()
        thinking = false
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
        if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
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
        ask(.opener, user: CoachPrompt.opener(calling: calling, details: recordDetails, style: openerStyle,
                                              scriptOpener: openerStyle == nil ? scriptOpenerLine() : nil))
    }

    /// The opener template filled in with their first name, your name and your company. No waiting.
    /// A ready-made voicemail, text and LinkedIn notes with their name, for when Claude
    /// can't write them in time. Still the right person, just not personalized.
    private func instantVoicemail(for calling: String?) -> Suggestion {
        let first = Screener.firstName(calling) ?? "there"
        let rep = (UserDefaults.standard.string(forKey: "repName") ?? "").trimmingCharacters(in: .whitespaces)
        let me = rep.isEmpty ? "[your name]" : rep
        var s = Suggestion()
        let key = recordKey()
        let texted = key.map { !DialHistory.person($0).texts.isEmpty } ?? false
        let leftBefore = key.map { !DialHistory.person($0).voicemails.isEmpty } ?? false
        let onLinkedIn = key.map { !DialHistory.person($0).linkedIns.isEmpty || !DialHistory.person($0).linkedInMessages.isEmpty } ?? false
        let linkedInLine = onLinkedIn ? " I also reached out on LinkedIn." : ""
        s.say = leftBefore
            ? "Hi \(first), \(me) from \(shortCompany) again. Still happy to share how teams like yours cut down on retyping info between systems.\(linkedInLine) \(texted ? "You have my number from my text." : "I'll text you my number.")"
            : "Hi \(first), this is \(me) with \(shortCompany). I help teams cut the time they spend retyping info between systems.\(linkedInLine) \(texted ? "I sent you a text earlier, so you have my number." : "I'll send you a quick text so you have my number.")"
        s.cue = "Ready-made voicemail (Claude didn't answer in time)."
        s.stage = "Voicemail"
        s.sayComplete = true
        // Plain and neutral on purpose: no pitch of their own, so they never clash with the campaign's tone.
        let texts = [
            "Hi \(first), \(me) with \(shortCompany). Just tried you and left a voicemail. I'll try you again tomorrow if I don't hear back.",
            "Hi \(first), \(me) again from \(shortCompany). Tried you once more today. Is now a busy season for you?",
            "\(first), \(me) at \(shortCompany). Still hoping to connect. Is there a better time of day to reach you?",
            "Hi \(first), \(me) from \(shortCompany). Should I keep trying you, or is now not a good time?",
            "\(first), last note from me (\(me), \(shortCompany)). I won't keep calling. Reach out anytime.",
        ]
        let sentBefore = recordKey().map { DialHistory.sentTexts($0).count } ?? 0
        s.textMessage = texts[sentBefore % texts.count]
        s.linkedin = "Hi \(first), I just tried calling you and left a voicemail. Would be glad to connect."
        let messages = [
            "Hi \(first), I just tried calling you and left a voicemail. Is there a good time to reach you this week?",
            "Hi \(first), following up on my call. Is there a better time of day to catch you?",
            "\(first), tried you again today. Happy to keep it short whenever works for you.",
            "Hi \(first), one more try. Worth a quick chat sometime, or not a fit right now?",
            "\(first), I'll stop reaching out after this. If timing changes, I'm happy to help.",
        ]
        let messagesBefore = recordKey().map { DialHistory.sentLinkedInMessages($0).count } ?? 0
        s.linkedinMessage = messages[messagesBefore % messages.count]
        applyScriptMessages(&s, for: calling)
        applyScriptVoicemail(&s, for: calling)
        return s
    }

    private func instantOpener(for calling: String?) -> Suggestion {
        // Rotation off: the campaign script's own opener, never a built-in one.
        // (Claude's version, fitted to them, replaces it a moment later.)
        if openerStyle == nil {
            if let line = scriptOpenerLine() {
                return Suggestion(say: fillBlanks(fillTags(line, for: calling), for: calling),
                                  cue: "Your script's opener", stage: "Opener", sayComplete: true)
            }
            return Suggestion(say: "Reading your script's opener...", cue: "Your script's opener", stage: "Opener", sayComplete: false)
        }
        var t = openerStyle?.template ?? Opener.all[0].template
        if t.contains("[a ") { t = Opener.all[0].template } // needs Claude to fill in; use the plain one
        let rep = (UserDefaults.standard.string(forKey: "repName") ?? "").trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "[first name]", with: Screener.firstName(calling) ?? "there")
            .replacingOccurrences(of: "[rep]", with: rep.isEmpty ? "[your name]" : rep)
            .replacingOccurrences(of: "[company]", with: shortCompany)
        return Suggestion(say: t, cue: openerStyle?.name ?? "Opener", stage: "Opener", sayComplete: true)
    }

    /// The script's first line for when they pick up: what Claude found reading the whole script,
    /// else the first quoted line of the campaign's Opening. Raw (blanks and placeholders as written).
    private func scriptOpenerLine() -> String? {
        let found = ScriptTemplates.shared.templates(for: campaignText) { [weak self] in self?.scriptRead() }
        if let line = found?.opener { return line }
        let opening = campaign.opening.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opening.isEmpty else { return nil }
        for (open, close) in [("\"", "\""), ("“", "”")] {
            if let a = opening.range(of: open), let b = opening.range(of: close, range: a.upperBound..<opening.endIndex) {
                return String(opening[a.upperBound..<b.lowerBound])
            }
        }
        return opening
    }

    /// "Is this ___?" → "Is this Adam?": a blank right after words that ask for the person.
    private func fillBlanks(_ text: String, for calling: String?) -> String {
        guard let first = Screener.firstName(calling) else { return text }
        var t = text
        for lead in ["is this", "am i speaking with", "speaking with", "is that", "calling for", "looking for", "hi", "hey", "hello"] {
            t = t.replacingOccurrences(of: #"(?i)\b(\#(lead))\s+_{2,}"#, with: "$1 \(first)", options: .regularExpression)
        }
        return t
    }

    /// The script was just read by Claude: refresh the card's templates and the opener on screen.
    private func scriptRead() {
        refillFromScript()
        if var v = voicemailScript, voicemailFor == calling {
            applyScriptVoicemail(&v, for: calling)
            voicemailScript = v
        }
        if status == .ready, openerStyle == nil { prepareOpener() }
    }

    /// Fills {first name}, {rep}, {company} and their [bracket] versions (any capitalization).
    private func fillTags(_ text: String, for calling: String?) -> String {
        var t = text
        let rep = (UserDefaults.standard.string(forKey: "repName") ?? "").trimmingCharacters(in: .whitespaces)
        let first = Screener.firstName(calling) ?? "there"
        let tags: [(names: [String], value: String)] = [
            (["first name", "firstname", "first", "name", "prospect", "prospect name"], first),
            (["rep", "rep name", "your name", "my name", "rep first name"], rep.isEmpty ? "[your name]" : rep),
            (["company", "your company", "rep company"], shortCompany),
        ]
        for (names, value) in tags {
            for n in names {
                for (o, c) in [("{", "}"), ("[", "]")] {
                    t = t.replacingOccurrences(of: o + n + c, with: value, options: .caseInsensitive)
                }
            }
        }
        return t
    }

    /// Everything the rep wrote in the campaign: each section, then the pasted script.
    private var campaignText: String {
        (Campaign.sections.map { campaign[keyPath: $0.key] } + [campaign.pastedScript]).joined(separator: "\n\n")
    }

    /// A message the campaign script spells out, found by its label (like "Missed call text:").
    /// The label must start the line (after any bullet). Takes the words after it on the same line, or the lines under it up to the next
    /// blank line or heading. Quotes around it are dropped. nil if the script has no such label.
    private func scriptPiece(_ labels: [String]) -> String? {
        let lines = campaignText.components(separatedBy: "\n")
        for label in labels {
            for (i, line) in lines.enumerated() {
                // Only a label at the start of a line (after bullets, numbers or "#"), not the
                // same words in the middle of a sentence.
                let head = String(line.drop { " \t#*-•–0123456789.)".contains($0) })
                // Little words don't matter: "Text after a missed call" matches "text after missed call".
                guard Self.plain(head).hasPrefix(Self.plain(label)) else { continue }
                // "Label: message" or "Label - message" or "Label “message”" = the message is on this line.
                // Anything else after the label ("(under 200 characters)", "/connection request") is
                // part of the heading, and the message is on the lines under it.
                var rest = ""
                if let colon = head.firstIndex(of: ":") {
                    rest = String(head[head.index(after: colon)...])
                } else if let q = head.firstIndex(where: { "\"“".contains($0) }) {
                    rest = String(head[q...])
                } else if let dash = head.range(of: " - ") ?? head.range(of: " – ") ?? head.range(of: " — ") {
                    rest = String(head[dash.upperBound...])
                }
                var body = rest.trimmingCharacters(in: .whitespaces)
                if body.isEmpty {
                    var under: [String] = []
                    for next in lines[(i + 1)...] {
                        let t = next.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty { if under.isEmpty { continue } else { break } }
                        if t.hasPrefix("#") || (t.hasSuffix(":") && t.count < 40) { break }
                        // The next label starts: stop.
                        let next = t.drop { " \t#*-•–0123456789.)".contains($0) }.lowercased()
                        if ["linkedin", "missed call", "voicemail", "sms", "email", "text message", "follow-up", "follow up"]
                            .contains(where: { next.hasPrefix($0) }) { break }
                        under.append(t)
                    }
                    body = under.joined(separator: " ")
                }
                body = ScriptTemplates.cleanTemplate(body)
                if body.count >= 15 { return String(body.prefix(1000)) }
            }
        }
        return nil
    }

    /// Lowercase, no "a", "an" or "the", single spaces, straight apostrophes: for matching labels.
    static func plain(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .filter { !["a", "an", "the"].contains($0) }
            .joined(separator: " ")
    }

    /// The campaign's own missed call text and LinkedIn notes win over anything written for them.
    /// The script's text is used for the first text to this person; later texts are written fresh
    /// in the same voice. The LinkedIn note and message fall back to the missed call text.
    private func applyScriptMessages(_ s: inout Suggestion, for calling: String?) {
        // Best: Claude read the whole script and found the templates (any headings, any layout).
        // Until that's done (a few seconds, once per script), a simple label match fills in.
        let found = ScriptTemplates.shared.templates(for: campaignText) { [weak self] in self?.scriptRead() }
            ?? labeledTemplates()
        // Text 1 is the missed call text, text 2 the next template, and so on. Past the last one, Claude writes them.
        let sent = recordKey().map { DialHistory.sentTexts($0).count } ?? 0
        if sent < found.texts.count { s.textMessage = fillTags(found.texts[sent], for: calling) }
        let text = found.texts.first
        if let n = found.linkedinNote ?? found.linkedinMessage ?? text { s.linkedin = fillTags(n, for: calling) }
        if let m = found.linkedinMessage ?? found.linkedinNote ?? text { s.linkedinMessage = fillTags(m, for: calling) }
    }

    /// The campaign script's voicemail, word for word with the blanks filled, in place of a written one.
    /// 1st voicemail to this person = the script's 1st, and so on. Past the last, Claude's version stays.
    private func applyScriptVoicemail(_ s: inout Suggestion, for calling: String?) {
        guard let found = ScriptTemplates.shared.templates(for: campaignText, onReady: { [weak self] in self?.scriptRead() }),
              !found.voicemails.isEmpty else { return }
        let left = recordKey().map { DialHistory.person($0).voicemails.count } ?? 0
        guard left < found.voicemails.count else { return }
        s.say = fillBlanks(fillTags(found.voicemails[left], for: calling), for: calling)
        s.cue = "Your script's voicemail. Wait for the beep."
    }

    /// The script was just read: put its templates on the open card (anything not sent yet).
    private func refillFromScript() {
        guard var f = followUp else { return }
        var s = Suggestion()
        applyScriptMessages(&s, for: calling)
        if !f.textDone, !s.textMessage.isEmpty { f.text = s.textMessage }
        if !f.linkedinDone, !s.linkedin.isEmpty { f.linkedin = s.linkedin }
        if !f.linkedinMessageDone, !s.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
        followUp = f
    }

    /// The quick fallback: templates found by their headings.
    private func labeledTemplates() -> ScriptTemplates.Found {
        let text = scriptPiece(["missed call text", "missed-call text", "missed call sms", "missed call message",
                                "text after missed call", "text after voicemail", "text after call", "voicemail text",
                                "text message", "sms", "missed call"])
        let second = scriptPiece(["if no reply", "if they don't reply", "if no response", "no reply", "second text",
                                  "2nd text", "text 2", "follow-up text", "follow up text"])
        let note = scriptPiece(["linkedin connection message", "linkedin connection request", "linkedin connection note",
                                "linkedin connect message", "linkedin connect", "linkedin connection",
                                "connection request", "linkedin note", "linkedin request", "connect note"])
        let message = scriptPiece(["linkedin message", "linkedin dm", "linkedin direct message", "linkedin follow"])
        let texts = text.map { [$0] + (second.map { [$0] } ?? []) } ?? []
        return ScriptTemplates.Found(texts: texts, linkedinNote: note, linkedinMessage: message)
    }

    /// "Clarity" from the campaign's company description.
    private var shortCompany: String {
        let c = campaign.company
        if c.localizedCaseInsensitiveContains("Clarity") { return "Clarity" }
        let first = c.components(separatedBy: CharacterSet(charactersIn: ",.;:")).first ?? ""
        let words = first.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? "Clarity" : words
    }

    private func ask(_ kind: Kind, user: String, early: String? = nil) {
        guard let key = Keychain.read(.anthropic) else {
            problem = "Add your Anthropic key: gear > Setup > AI keys."
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
                ActivityLog.problem("Claude error: \(error.localizedDescription)")
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
