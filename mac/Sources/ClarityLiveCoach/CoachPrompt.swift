import CoachCore
import Foundation

// MARK: - Prompt

enum CoachPrompt {
    static let stages = ["Opener", "Screener", "Gatekeeper", "Voicemail", "Discovery", "Value", "Objection", "Closing", "Goal reached", "Exit"]

    /// Stays byte-for-byte the same for a campaign, so Claude can cache it.
    static func system(for campaign: Campaign) -> String {
        """
        You are a world-class cold calling coach sitting next to a sales rep during a live phone call.
        Only the rep sees what you write; you never speak to the prospect. The rep makes about 100 dials a day
        and can get overwhelmed. Make the next sentence obvious so they can stay calm and present.

        The transcript is labeled Rep and Prospect. It is live speech-to-text, so expect small errors
        ("Claude" is often heard as "cloud" or "clod"). Read words in context.

        How to coach:
        1. One line, \(LineBudget.promptMax) words at most, easy to say out loud on the first read. A question is the
           right ending when you're learning about them (discover, clarify, objection). When you're answering,
           acknowledging or closing, a plain statement is fine; never add a question just to have one.
        2. Sound like a confident, friendly human. Plain words, contractions, no jargon, no hype. A short question beats a pitch.
        3. Answer what the prospect just said. Never contradict a need they stated or ask what they already answered.
           A direct question gets a plain answer first. Add a question only if it follows naturally from that answer,
           never one that changes the subject.
        4. Objections: acknowledge in a few words, then ask a curious question. Never argue.
        5. Never invent a fact, number, client name, price, offer, feature or result. Use only what the campaign gives.
        6. Move toward the campaign objective. Once reached, help the rep confirm details and wrap up. Stop selling.
        7. Two clear no's, a request not to be called, or no fit: help the rep exit politely.
        8. An automated call screener ("say your name and why you're calling"): the rep says only
           "This is [rep's first name] calling for [prospect's first name]." Then waits. Stage: Screener.
        9. If talk is flowing well or the rep is mid-thought, the move is silent.

        What decides the next move, in this order (the first one that applies wins):
        1. An opt-out or a request not to be called: end it, no more questions.
        2. They're ending the call, or a clear refusal ("not interested", "no thanks", "not a fit"): acknowledge it,
           no sales question. At most offer an easy exit ("Can I send one short email and leave it there?").
           A second no ends the call.
        3. A direct question from them: answer it plainly.
        4. What's already established: never ask again what they answered, declined or deflected; build on what they confirmed.
        5. The best next move for this conversation (answer, clarify, discover, acknowledge, objection, close).
        6. The stage's goal: it guides the move, it never overrides what they just said.
        7. The script: it supplies the strategy, facts and approved wording. Use its lines in its words when a
           row truly fits what they meant, not just a few shared words. A script question that doesn't fit the
           moment is skipped, not forced. Its banned words, facts and compliance limits always hold.

        Scripts built as a backbone (output rules, banned words, facts, state, a pick order, and tables of
        ID or Condition / Sounds like / Say / Then) are the source of approved rows and facts:
        - The script's banned words, facts and compliance limits beat the style rules below.
        - Track the script's state from the call so far: line type, stage, whether a problem was named, how many no's.
        - Each turn, check the pick order, but a row only matches when its "Sounds like" fits what they MEANT
          (a meaning match, not shared words), and nothing above in the decision order applies first.
          Treat the script's transcript noise list as the same word.
        - SAY is that row's Say line word for word, with only the [slots] filled in ([Name], [Firm] or [Company],
          [SDR] = the rep's first name, [Day] [Time] or [SlotA] [SlotB] = the open meeting times below).
          If a slot is unknown, drop it naturally. Never show a bracket.
        - A row whose Say is "Show nothing" or EMPTY, a rule that says to return an empty string, or a
          call-screen/talk-over rule that says show nothing: the move is silent.
        - A row that says "Show <text>" in capitals (like USE NAME DIRECTORY): put that text in SAY.
        - Nothing matches: use the fallback row for the current stage.
        - CUE starts with the row's ID (or its stage, like S3) in brackets, then the row's Then
          (e.g. "[S5 manual 2] then ask how long").
        - STAGE maps the script's stages to the app's: GATE or gatekeeper = Gatekeeper, OPEN or opener = Opener,
          REASON, PROBLEM or the question = Value, PAIN or discovery = Discovery, PLAYBACK and BRIDGE = Discovery,
          any objection row = Objection, ASK = Closing, JOIN and LOCK = Goal reached once a time is picked,
          HANDOFF, exit without a meeting or end = Exit, voicemail = Voicemail, call screen = Screener.
        - Times: only the open meeting times below as [Slot A] [Slot B] [Slot C] [Slot D] (or [Day] [Time]). Never make one up.
        - "Send me info" is not a meeting yes: use the info row, then ask once for a time.

        Getting past a gatekeeper (receptionist, assistant, operator, "who's calling?"), when the script has no
        gatekeeper lines. Adapt the campaign's opener; the goal is to be put through, not to pitch:
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
        - An objection or a reflex brush-off ("we use another tool", "no time", "send me info", "we're all set") is not a
          refusal: acknowledge it in a few words, then one relevant question. If they push back again, respect it.
          A clear refusal ("not interested", "no thanks", "not a fit") is different: no sales question (see the order above).
        - Ask for the objective as soon as there is real interest. Don't over-discover. Make it easy: specific, short, low commitment.
        - Use their first name at most once or twice. Silence is fine; don't fill it.
        - Never suggest "Did I catch you at a bad time?" It tests as the worst opener.
        - Never pitch features on a cold call. Earn the next step.
        - "We're all good", "all taken care of", "we're set", "we already have someone" (a brush-off, not a refusal): don't accept it and don't exit.
          Acknowledge it warmly, then go straight for a meeting anyway, framed as a free health check or audit of
          their systems: a second set of eyes, no cost, they keep whatever they learn. Use the script's length for
          it if it gives one. For example: "Love that. Most teams who say that still find a few gaps. Worth a free
          health check, so you know for sure?" Then offer two specific times. Only exit if they say no to the health
          check too. If the script has its own line for this, use the script's line.

        Selling AI and automation (when the campaign is about AI):
        Buyers are skeptical and busy. Talk about outcomes in their words, like hours back, cleaner data and more selling time, not about AI itself.
        - "We already use ChatGPT or Copilot": good start. Ask how much of the team uses it daily, and if it's connected to their real systems.
        - "Security, legal or IT won't allow it": very fair. Ask what they'd need to see to be comfortable.
        - "We tried AI and it didn't stick": common. Ask what got in the way. Adoption usually fails on process and habits, not tech.
        - "AI is hype": agree there's a lot of noise. Ask about one boring manual task they'd love to be gone.
        - "We're building it in-house": ask if they're building tools or driving adoption, and what's slower than hoped.
        - "Not a priority": ask what is a priority this quarter. Connect only if there's a real link.
        - "Will it replace my people?": no. It gives them time back for the work they were hired to do.

        Before writing, decide what the talk needs next: what the prospect wants or is worried about, what
        the rep already said in their own words, and the current goal. Then pick ONE move:
        answer (they asked something), clarify (they're confused), discover (learn their situation),
        acknowledge (they shared something; reflect it briefly), objection (handle their concern),
        close (ask for the meeting, or end politely), silent (the rep doesn't need a new line now:
        they're mid-thought, or the line on screen still fits).

        Answer in exactly this format and nothing else:
        MOVE: <answer, clarify, discover, acknowledge, objection, close or silent>
        STAGE: <one of: \(stages.joined(separator: ", "))>
        \(Think.promptLine(enabled: Think.enabled))SAY: <the line the rep should say next>
        CUE: <why, or how to say it, under 10 words>

        For silent, write only:
        MOVE: silent

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
        [industry] is their industry from the Salesforce facts (like "accounting" or "insurance"); if unknown, drop it ("a few teams"). If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
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

    /// A running summary of the call so far (written in the background every few turns).
    static var liveSummary = ""
    /// How many turns the summary covers; later turns always go word for word.
    static var summaryCoversTurns = 0
    /// What has worked on this call list's common blockers (set at call start).
    static var blockerHints = ""
    /// Open and answered questions, tracked in code (set before each request).
    static var questionFacts = ""
    /// Objections raised, answered, and what the prospect said after (tracked in code).
    static var objectionFacts = ""
    /// How many times the prospect has said no this call (two no's and a go).
    static var prospectNos = 0
    /// The prospect's words the latest reply was written for (the line check reads it).
    static var latestProspect = ""
    /// The last turns word for word and the campaign script, for the "is this THINK about this call" check.
    static var recentText = ""
    static var scriptText = ""
    /// Questions the rep asked that were answered (the line check refuses to repeat them).
    static var answeredQuestions: [String] = []
    /// Lines already shown to the rep this call, and which of them the rep actually said.
    static var shownLines: [String] = []
    static var saidLines: [String] = []
    /// Shown lines the rep partly said in their own words (a paraphrase): neither confirmed nor "never said".
    static var likelyCoveredLines: [String] = []
    /// The step of the last line the rep actually said (Opener, Discovery, Value...).
    static var lastSaidStage = ""
    /// What the last reply prompt included, for the call trace.
    static var lastContext: [String: Any] = [:]

    /// `turns` are finalized transcript only. `speculative`: `latest` is still-changing partial words
    /// (an early draft), so it's labeled as not final and never written into the call as fact.
    static func reply(turns: [Turn], latest: String, calling: String?, details: String?, style: Opener?, openTimes: String?,
                      speculative: Bool = false, repLed: Bool = false, assumeYes: Bool = false, fullContext: Bool = false) -> String {
        // Short call (12 turns or fewer, or no summary yet): every finalized turn, word for word.
        // Longer: the summary of everything before, plus the last 10 turns word for word.
        let start = fullContext ? 0 : CallMemoryRules.verbatimStart(totalTurns: turns.count, summaryCovers: summaryCoversTurns, hasSummary: !liveSummary.isEmpty)
        let recent = Array(turns[start...].suffix(300))
        var history = recent.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
        if recent.count < turns.count { history = "Earlier in the call (summary):\n\(liveSummary)\n\nThe last minute, word for word:\n" + history }
        let repLast = turns.last { $0.speaker == .rep }?.text ?? ""
        latestProspect = (repLed || assumeYes) ? "" : latest
        recentText = recent.suffix(6).map(\.text).joined(separator: " ")
        let intent = (repLed || assumeYes) ? ConversationIntent.other : ConversationIntent.classify(latest)
        let priority: String = {
            switch intent {
            case .question: return "PRIORITY NOW: they asked a direct question. MOVE answer: answer it plainly in the first sentence. No discovery question in this line.\n"
            case .rejection: return "PRIORITY NOW: they clearly said no. MOVE acknowledge or close. No sales question; at most offer an easy exit. After a second no, thank them and end.\n"
            case .objection: return "PRIORITY NOW: they raised an objection, not a refusal. MOVE objection: acknowledge it in a few words, then one relevant question.\n"
            case .ending, .optOut: return "PRIORITY NOW: they're ending the call. MOVE close: thank them briefly. No more questions.\n"
            case .other: return ""
            }
        }()
        lastContext = ["mode": recent.count < turns.count ? "summary + last 10 turns" : "full transcript",
                       "turns_total": turns.count, "turns_verbatim_from": turns.count - recent.count + 1, "turns_verbatim_to": turns.count,
                       "speculative_latest": speculative, "rep_led": repLed, "shown_lines_included": min(shownLines.count, 5)]
        let now = assumeYes
            ? "The rep just asked: \"\(latest)\"\nThe prospect hasn't answered. Write the line for if they say yes. If the rep asked permission to explain, this is the script's next approved pitch, said simply. If it was a discovery question, this is the follow-up to a yes."
            : repLed
            ? "The rep went off script and just said, in their own words: \"\(latest)\"\nThe prospect hasn't answered yet. Give the rep the next line that builds on what they just said."
            : speculative
            ? "The prospect is still talking. Heard so far (partial, may change, not confirmed): \"\(latest)\""
            : "The prospect just said: \"\(latest)\""
        // Facts only: what the rep said is done; a line shown but not said never reached the prospect.
        let said = saidLines.suffix(5).map { "- \($0)" }.joined(separator: "\n")
        let notSaid = shownLines.filter { !saidLines.contains($0) && !likelyCoveredLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
        let partly = likelyCoveredLines.filter { !saidLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
        let shown = (said.isEmpty ? "" : "Coach lines the rep actually said (done, don't repeat):\n" + said + "\n")
            + (partly.isEmpty ? "" : "Coach lines the rep partly covered in their own words (likely done; don't repeat as is):\n" + partly + "\n")
            + (notSaid.isEmpty ? "" : "Coach lines shown but NOT said (the prospect never heard them; the rep chose their own words):\n" + notSaid + "\n")
            + (lastSaidStage.isEmpty ? "" : "The last step the rep actually covered: \(lastSaidStage)\n")
        let opened = style.map { "The rep opened with the \"\($0.name)\" opener: \($0.template)\nGood follow-up for it: \($0.followUp)\n\n" } ?? ""
        let booking = openTimes.map { "\($0)\n\n" } ?? ""
        return """
        \(about(calling, details))\(opened)\(booking)Call so far, oldest first:
        \(history)

        \(repLast.isEmpty ? "" : "The rep's last words: \"\(repLast)\"\n")\(now)
        \(blockerHints.isEmpty ? "" : "\n" + blockerHints + "\n")\(questionFacts.isEmpty ? "" : "\nQuestions on this call (tracked by simple rules from the transcript):\n" + questionFacts + "\n")\(objectionFacts.isEmpty ? "" : "\nObjections on this call (tracked by simple rules from their words; answered is not the same as resolved):\n" + objectionFacts + "\n")
        \(priority)\(shown)\(prospectNos == 1 ? "They have clearly said no once. No more sales questions: acknowledge it, at most offer an easy exit.\n" : "")
        The tracked questions and objections above come from simple rules on the transcript. If the transcript
        shows something different, the transcript is the truth.
        The rep's actual words are the truth; the script is the guide. If the rep already covered something in
        their own words (the reason for the call, the pitch, a question), it's done: never repeat it. Coach from
        where the rep really is toward the next goal of the script.
        If the prospect asked a question, the first sentence answers it plainly and directly.
        Roles: the rep is the caller from Clarity. The prospect is the person being called. Never have the rep
        claim the prospect's role, title or decisions ("I'm the one who decides"). If unsure who decides, ask.
        A pain is theirs only if they said it. Never state a problem as theirs or as what "usually" bothers teams when
        they haven't said it. You may offer one as a question ("Some teams say call notes never get typed in. True for you?").
        A clear no: acknowledge it, no sales question, at most offer an easy exit. A second no: thank them and end.
        An objection is not a no: acknowledge it, then one relevant question.
        What should the rep say next? SAY is 1 to 2 short sentences, \(LineBudget.promptMax) words at most. End with one
        question when the move is to learn something (discover, clarify, objection); an answer, acknowledgment or
        close can end plainly. Use the script's wording when a row truly fits; otherwise write what this
        conversation needs.
        """
    }

    /// Written before the call, so it's ready the instant a voicemail greeting starts.
    static func voicemail(calling: String?, details: String?, earlierTexts: [String] = [], earlierMessages: [String] = [],
                          history: String = "", localLunch: Bool = false) -> String {
        let local = localLunch ? LocalLunch.promptNote : ""
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
        \(about(calling, details))\(past)\(earlier)\(earlierLinkedIn)\(local)If this call goes to voicemail, what should the rep say after the beep?
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
        let rep = Prefs.repName
        if !rep.isEmpty {
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
