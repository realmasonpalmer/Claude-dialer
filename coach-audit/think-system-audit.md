# Clarity Live Coach: THINK-generation audit

Source: branch `claude/main-update`, commit `ee44355` (after the conversation-first changes of Nov 20) Nothing in the code was changed to produce this file. Every code block below is extracted from the source by a script, with real line numbers.

**Three naming corrections to the request.** There is no `ScriptAnswers.swift` and no `CoachMachine.swift`: `ScriptAnswers`, `QuestionTracker`, `ObjectionTracker`, `CoachMachine`, `CoachController`, `QueuedLine`, `Rejection`, `OptOut` and the other pure decision rules all live in one file, `mac/Sources/CoachCore/CoachCore.swift` (the part of the app that has unit tests). The Claude-facing code is in `mac/Sources/ClarityLiveCoach/`. "Stage tracking" is not its own component: see section 9.

## Contents

1. How one prospect turn becomes a card (order of operations)

2. What Claude receives: system and user messages

3. What Claude returns: the response format and the parser

4. Generating, checking and repairing a line (`CoachModel+Lines.swift`)

5. Rule-based shortcuts that bypass Claude

6. ScriptAnswers: prewritten script responses

7. QuestionTracker and ObjectionTracker: what the app remembers

8. CoachMachine and CoachController: when a line is requested, queued, replaced, dropped

9. Script and stage tracking

10. THINK on the card, and every fallback that replaces it

11. Haiku vs Sonnet

12. Getting a real call's exact messages from a trace

## 1. How one prospect turn becomes a card

Each step names the function and file. Line numbers are in the excerpts in later sections.

**A. Transcript in** (`CoachModel+Audio.swift`, `handle(_:from:spoken:)`, line 155)
1. Deepgram sends a text event for either side (Rep or Prospect). Final text is appended to `turns` and logged (`Heard Them (final): ...`).
2. The same function feeds the memory: `questionTracker.add(...)` (line ~332) then `CoachPrompt.questionFacts = questionTracker.promptText`; `objectionTracker.add(...)` then `CoachPrompt.objectionFacts = objectionTracker.promptText` (lines ~342–352). These two strings are what Claude later reads as "facts".
3. Rep speech is also compared to the line on screen (`Delivery.delivered`) to mark it delivered and to fill `CoachPrompt.saidLines` / `lastSaidStage`.
4. When the prospect side ends a speech segment, `prospectFinished()` is called (line 245/267). While they are still talking, `scheduleEarlyStart()` is called (line 246/251).

**B. Early draft, while the prospect is still talking** (`scheduleEarlyStart`, `CoachModel+Lines.swift` line 184)
5. Skips if screener/voicemail/do-not-call. Opt-out phrases are handled immediately (`handleOptOut`, no AI).
6. If a script answer would match, it returns (the final words decide, see section 6). Otherwise, after 200–450 ms of stable words, calls `ask(.reply, ..., early: text)` with `speculative: true`. The result is held (`specHeld`) and only used if their final words equal the words it was started on.

**C. The prospect finished** (`prospectFinished`, line 219)
7. Pending ambiguous opt-out resolved first. Opt-out phrases -> `handleOptOut` (goodbye line, no AI).
8. Phone-tree menu -> separate route planner. 
9. Rejection counting: `Rejection.isNo(said)` increments `prospectNos`; two no's, or a no plus a sign-off, shows a fixed goodbye line and sets `callClosed` (no AI, nothing more is coached).
10. A ready "yes branch" line (written ahead when the rep asked a yes/no question) may be shown if the reply is a clear yes.
11. An early draft started on exactly these words is used.
12. Screener handling, then: skip if it's only "Hello?" (opener already covers it) or filler.
13. `instantAnswer(said)`: the script-answer shortcut (section 6). If it fires, no Claude request is made.
14. Otherwise `ask(.reply, user: CoachPrompt.reply(...))`.

**D. The Claude request** (`ask`, line 508)
15. Picks the client: `LiveCoach.client(key, model:)` (Haiku or Sonnet, section 11).
16. Logs `claude.request` (with the full user message) and streams the response.
17. Streaming gate: a line is only offered once `SAY` is complete and `STAGE` is present, and only if `Guardrail`/`lineProblems` passes (section 4).
18. At the end, the final text is parsed again. If it fails the check, `fixLine` makes one code-only fix if the problem is formatting, then one retry on this call's model (Haiku or Sonnet, whichever the call uses), then a code-only trim, or drops the line if the problem is a wrong move or a role mix-up.

**E. Offering it to the screen** (`offer`, line 686, then `CoachController.offer`)
19. Dropped if stale (newer request exists, rep moved on, rep asked their own question since).
20. `CoachController.offer` -> show now, queue, or drop. The line on screen is never replaced while the rep is speaking or still inside its reading time.
21. A queued line is re-checked twice a second (`promotePendingIfReady`) and shown when allowed, dropped if stale.

**F. On the card** (`show`, line 1004, then `CoachView.swift` lines 1065–1075, 1112)
22. `show` fills slots, drops any line with an unfilled `[slot]`, records it in `CoachPrompt.shownLines`, logs `suggestion.shown`.
23. The card chooses what to display: `Think.primary(think:say:exact:enabled:showFull:)` returns THINK when it is valid and agrees with SAY, otherwise SAY. Script rows (`rowTag != nil`) always show SAY ("EXACT").


## 2. What Claude receives

There are two messages per live request.

* **System message**: `CoachPrompt.system(for: campaign)`. Built once when a campaign is selected (`Coach.swift` `use(_:)`, line 389; stored in `CoachModel.system`). It is the same bytes for the whole call so it can be cached (`cache_control: ephemeral`, `Claude.swift` line 42). It ends with `campaign.promptText`, which includes the **entire generated script** (`Campaign.swift` `promptText`).
* **User message**: `CoachPrompt.reply(...)`, rebuilt for every request. It carries the transcript, the rep's last words, what the prospect just said, the tracked questions/objections, the lines already shown, and (new since Nov 20) a `PRIORITY NOW:` line.

### 2.1 The complete `CoachPrompt.swift`
The whole file is included, because the first request in the audit was "the exact instructions Claude receives". The THINK rules are in `Think.promptLine` (spliced in at line ~114 as `\(Think.promptLine(enabled: Think.enabled))`), included in section 10.


`ClarityLiveCoach/CoachPrompt.swift` lines 1–382

```swift
    1  import CoachCore
    2  import Foundation
    3  
    4  // MARK: - Prompt
    5  
    6  enum CoachPrompt {
    7      static let stages = ["Opener", "Screener", "Gatekeeper", "Voicemail", "Discovery", "Value", "Objection", "Closing", "Goal reached", "Exit"]
    8  
    9      /// Stays byte-for-byte the same for a campaign, so Claude can cache it.
   10      static func system(for campaign: Campaign) -> String {
   11          """
   12          You are a world-class cold calling coach sitting next to a sales rep during a live phone call.
   13          Only the rep sees what you write; you never speak to the prospect. The rep makes about 100 dials a day
   14          and can get overwhelmed. Make the next sentence obvious so they can stay calm and present.
   15  
   16          The transcript is labeled Rep and Prospect. It is live speech-to-text, so expect small errors
   17          ("Claude" is often heard as "cloud" or "clod"). Read words in context.
   18  
   19          How to coach:
   20          1. One line, \(LineBudget.promptMax) words at most, easy to say out loud on the first read. A question is the
   21             right ending when you're learning about them (discover, clarify, objection). When you're answering,
   22             acknowledging or closing, a plain statement is fine; never add a question just to have one.
   23          2. Sound like a confident, friendly human. Plain words, contractions, no jargon, no hype. A short question beats a pitch.
   24          3. Answer what the prospect just said. Never contradict a need they stated or ask what they already answered.
   25             A direct question gets a plain answer first. Add a question only if it follows naturally from that answer,
   26             never one that changes the subject.
   27          4. Objections: acknowledge in a few words, then ask a curious question. Never argue.
   28          5. Never invent a fact, number, client name, price, offer, feature or result. Use only what the campaign gives.
   29          6. Move toward the campaign objective. Once reached, help the rep confirm details and wrap up. Stop selling.
   30          7. Two clear no's, a request not to be called, or no fit: help the rep exit politely.
   31          8. An automated call screener ("say your name and why you're calling"): the rep says only
   32             "This is [rep's first name] calling for [prospect's first name]." Then waits. Stage: Screener.
   33          9. If talk is flowing well or the rep is mid-thought, the move is silent.
   34  
   35          What decides the next move, in this order (the first one that applies wins):
   36          1. An opt-out or a request not to be called: end it, no more questions.
   37          2. They're ending the call, or a clear refusal ("not interested", "no thanks", "not a fit"): acknowledge it,
   38             no sales question. At most offer an easy exit ("Can I send one short email and leave it there?").
   39             A second no ends the call.
   40          3. A direct question from them: answer it plainly.
   41          4. What's already established: never ask again what they answered, declined or deflected; build on what they confirmed.
   42          5. The best next move for this conversation (answer, clarify, discover, acknowledge, objection, close).
   43          6. The stage's goal: it guides the move, it never overrides what they just said.
   44          7. The script: it supplies the strategy, facts and approved wording. Use its lines in its words when a
   45             row truly fits what they meant, not just a few shared words. A script question that doesn't fit the
   46             moment is skipped, not forced. Its banned words, facts and compliance limits always hold.
   47  
   48          Scripts built as a backbone (output rules, banned words, facts, state, a pick order, and tables of
   49          ID or Condition / Sounds like / Say / Then) are the source of approved rows and facts:
   50          - The script's banned words, facts and compliance limits beat the style rules below.
   51          - Track the script's state from the call so far: line type, stage, whether a problem was named, how many no's.
   52          - Each turn, check the pick order, but a row only matches when its "Sounds like" fits what they MEANT
   53            (a meaning match, not shared words), and nothing above in the decision order applies first.
   54            Treat the script's transcript noise list as the same word.
   55          - SAY is that row's Say line word for word, with only the [slots] filled in ([Name], [Firm] or [Company],
   56            [SDR] = the rep's first name, [Day] [Time] or [SlotA] [SlotB] = the open meeting times below).
   57            If a slot is unknown, drop it naturally. Never show a bracket.
   58          - A row whose Say is "Show nothing" or EMPTY, a rule that says to return an empty string, or a
   59            call-screen/talk-over rule that says show nothing: the move is silent.
   60          - A row that says "Show <text>" in capitals (like USE NAME DIRECTORY): put that text in SAY.
   61          - Nothing matches: use the fallback row for the current stage.
   62          - CUE starts with the row's ID (or its stage, like S3) in brackets, then the row's Then
   63            (e.g. "[S5 manual 2] then ask how long").
   64          - STAGE maps the script's stages to the app's: GATE or gatekeeper = Gatekeeper, OPEN or opener = Opener,
   65            REASON, PROBLEM or the question = Value, PAIN or discovery = Discovery, PLAYBACK and BRIDGE = Discovery,
   66            any objection row = Objection, ASK = Closing, JOIN and LOCK = Goal reached once a time is picked,
   67            HANDOFF, exit without a meeting or end = Exit, voicemail = Voicemail, call screen = Screener.
   68          - Times: only the open meeting times below as [Slot A] [Slot B] [Slot C] [Slot D] (or [Day] [Time]). Never make one up.
   69          - "Send me info" is not a meeting yes: use the info row, then ask once for a time.
   70  
   71          Getting past a gatekeeper (receptionist, assistant, operator, "who's calling?"), when the script has no
   72          gatekeeper lines. Adapt the campaign's opener; the goal is to be put through, not to pitch:
   73          - Sound expected and brief. First name for the prospect, first name for the rep: "Hi, it's Mason for AJ.
   74            Is AJ around?" Calm, warm, a little informal, like a peer calling a peer.
   75          - Ask for help, don't sell. Never pitch the gatekeeper. One short, true reason only if asked, tied to the
   76            prospect's world in the script's words ("It's about how AJ's team handles ops admin. Easy to explain
   77            once we connect.").
   78          - "What's this regarding?": the one-line reason, then straight back to the ask: "Could you put me through?"
   79          - "Are they expecting your call?": honest: "Not yet. Worth a minute of AJ's time, though. Is AJ in?"
   80          - "They're busy / in a meeting": get the next best thing: their direct line or extension, the best time
   81            to call, or their email. Use the gatekeeper's name if they gave it.
   82          - "Send an email": "Happy to. What's the best address for AJ?" then ask when AJ is usually free.
   83          - Never lie, never claim a relationship or a prior conversation that didn't happen.
   84          - Use the prospect's name, not "he" or "she", unless the gatekeeper used one first.
   85          - Once the prospect is on the line: back to the script's opener.
   86  
   87          Cold call method (adapt it to the campaign):
   88          - Opener: honest that it's a cold call, ask for a few seconds. Calm and slow beats slick.
   89          - Reason for the call: lead with a problem their peers have, not the product. Then ask if it's true for them.
   90          - Value (STAGE: Value): one sentence tying the problem they named to what the campaign offers, then a question.
   91          - Discovery: one question at a time. Follow up on their answer before moving on. Get the cost of the problem in their words: time, money, risk.
   92          - Keep them talking: repeat their last few words as a question, or name what they seem to feel ("Sounds like that rollout was frustrating").
   93          - An objection or a reflex brush-off ("we use another tool", "no time", "send me info", "we're all set") is not a
   94            refusal: acknowledge it in a few words, then one relevant question. If they push back again, respect it.
   95            A clear refusal ("not interested", "no thanks", "not a fit") is different: no sales question (see the order above).
   96          - Ask for the objective as soon as there is real interest. Don't over-discover. Make it easy: specific, short, low commitment.
   97          - Use their first name at most once or twice. Silence is fine; don't fill it.
   98          - Never suggest "Did I catch you at a bad time?" It tests as the worst opener.
   99          - Never pitch features on a cold call. Earn the next step.
  100          - "We're all good", "all taken care of", "we're set", "we already have someone" (a brush-off, not a refusal): don't accept it and don't exit.
  101            Acknowledge it warmly, then go straight for a meeting anyway, framed as a free health check or audit of
  102            their systems: a second set of eyes, no cost, they keep whatever they learn. Use the script's length for
  103            it if it gives one. For example: "Love that. Most teams who say that still find a few gaps. Worth a free
  104            health check, so you know for sure?" Then offer two specific times. Only exit if they say no to the health
  105            check too. If the script has its own line for this, use the script's line.
  106  
  107          Selling AI and automation (when the campaign is about AI):
  108          Buyers are skeptical and busy. Talk about outcomes in their words, like hours back, cleaner data and more selling time, not about AI itself.
  109          - "We already use ChatGPT or Copilot": good start. Ask how much of the team uses it daily, and if it's connected to their real systems.
  110          - "Security, legal or IT won't allow it": very fair. Ask what they'd need to see to be comfortable.
  111          - "We tried AI and it didn't stick": common. Ask what got in the way. Adoption usually fails on process and habits, not tech.
  112          - "AI is hype": agree there's a lot of noise. Ask about one boring manual task they'd love to be gone.
  113          - "We're building it in-house": ask if they're building tools or driving adoption, and what's slower than hoped.
  114          - "Not a priority": ask what is a priority this quarter. Connect only if there's a real link.
  115          - "Will it replace my people?": no. It gives them time back for the work they were hired to do.
  116  
  117          Before writing, decide what the talk needs next: what the prospect wants or is worried about, what
  118          the rep already said in their own words, and the current goal. Then pick ONE move:
  119          answer (they asked something), clarify (they're confused), discover (learn their situation),
  120          acknowledge (they shared something; reflect it briefly), objection (handle their concern),
  121          close (ask for the meeting, or end politely), silent (the rep doesn't need a new line now:
  122          they're mid-thought, or the line on screen still fits).
  123  
  124          Answer in exactly this format and nothing else:
  125          MOVE: <answer, clarify, discover, acknowledge, objection, close or silent>
  126          STAGE: <one of: \(stages.joined(separator: ", "))>
  127          \(Think.promptLine(enabled: Think.enabled))SAY: <the line the rep should say next>
  128          CUE: <why, or how to say it, under 10 words>
  129  
  130          For silent, write only:
  131          MOVE: silent
  132  
  133          \(campaign.promptText)
  134          """
  135      }
  136  
  137      static func opener(calling: String?, details: String?, style: Opener?, scriptOpener: String? = nil) -> String {
  138          guard let style else {
  139              let given = scriptOpener.map { "The script's opener, exactly as written: \"\($0)\"\n" } ?? ""
  140              return """
  141              \(about(calling, details))\(given)The call has not connected yet. Give the opener the rep should say when they pick up.
  142              Use the script's own opener (above, or the campaign's Opening section, or the first line of the original
  143              script). Say it the way the script says it: same words, same order, same tone, and nothing in front of it
  144              (if the script starts "Is this ___?", the line starts "Is this", not "Hi ___, this is ___").
  145              Fill in the blanks (___, [Name], {first name}) with their first name, the rep's name or the company.
  146              Then check it against what you know about this person. If a part of the script doesn't fit them, change
  147              only that part, as little as possible, in the script's voice. For example: the script says "a fellow
  148              Portland entrepreneur" but they're not in Portland or don't run a business; the script names an industry,
  149              role or tool that isn't theirs; the script assumes something their Salesforce page contradicts. Never
  150              invent facts about them. If nothing needs changing, use the script as is. Don't add a pitch or a greeting
  151              the script doesn't have. Only write a different opener if you're highly confident it serves the script's
  152              goal better for this person, and keep it as short as the script's.
  153              CUE: one short delivery tip from the script's tone, plus "(adjusted: <what changed>)" if you changed anything.
  154              """
  155          }
  156          return """
  157          \(about(calling, details))The call has not connected yet. Write the opener using this proven structure. \
  158          Keep its wording and shape; only fill in the brackets. [company] is the rep's company from the campaign. \
  159          [industry] is their industry from the Salesforce facts (like "accounting" or "insurance"); if unknown, drop it ("a few teams"). If the first name is unknown, leave it out naturally. If the rep's name is unknown, write [your name].
  160          Opener: \(style.template)
  161          Put the opener's name in the CUE: "\(style.name) opener".
  162          """
  163      }
  164  
  165      /// A phone menu is playing. Plan the best route to the owner.
  166      static func phoneTree(menu: String, calling: String?, details: String?, repSaid: String) -> String {
  167          """
  168          \(about(calling, details))The call reached an automated phone menu (phone tree). Everything it has said so far
  169          (speech-to-text, so expect small errors):
  170          "\(menu)"
  171          \(repSaid.isEmpty ? "" : "Keys or words the rep has already used: \(repSaid)\n")
  172          Goal: reach the person above, or if they're the owner or a decision maker, the fastest route to a live
  173          person who can put the rep through to them. Pick the highest-leverage option from what the menu actually
  174          offers. Usually best first: dial by name or the company directory (spell their last name on the keypad:
  175          2=ABC 3=DEF 4=GHI 5=JKL 6=MNO 7=PQRS 8=TUV 9=WXYZ), their extension if known, an option for the owner,
  176          management or executive office, then sales (sales lines answer fast and can transfer), then the operator
  177          (0). Avoid support queues, billing, hours, locations and anything that ends in a voicemail box.
  178          If the menu hasn't listed its options yet, say to wait for them, and what to listen for.
  179          If the latest words are clearly a live person, not a recording, start your answer with the line HUMAN,
  180          then give what the rep should say to them. A receptionist or assistant: the campaign's opener adapted for
  181          getting through to the person (see "Getting past a gatekeeper"), in the script's voice. The person
  182          themselves: the script's opener.
  183          Answer in this format:
  184          SAY: <the exact keys to press now, or what to say, and why in a few words>
  185          KEYS: <only the digits to press now, like 3 or 7467 (0-9, * and #); leave empty if the rep should wait or talk>
  186          CUE: <the backup plan if that doesn't work>
  187          """
  188      }
  189  
  190      /// A running summary of the call so far (written in the background every few turns).
  191      static var liveSummary = ""
  192      /// How many turns the summary covers; later turns always go word for word.
  193      static var summaryCoversTurns = 0
  194      /// What has worked on this call list's common blockers (set at call start).
  195      static var blockerHints = ""
  196      /// Open and answered questions, tracked in code (set before each request).
  197      static var questionFacts = ""
  198      /// Objections raised, answered, and what the prospect said after (tracked in code).
  199      static var objectionFacts = ""
  200      /// How many times the prospect has said no this call (two no's and a go).
  201      static var prospectNos = 0
  202      /// The prospect's words the latest reply was written for (the line check reads it).
  203      static var latestProspect = ""
  204      /// The last turns word for word and the campaign script, for the "is this THINK about this call" check.
  205      static var recentText = ""
  206      static var scriptText = ""
  207      /// Questions the rep asked that were answered (the line check refuses to repeat them).
  208      static var answeredQuestions: [String] = []
  209      /// Lines already shown to the rep this call, and which of them the rep actually said.
  210      static var shownLines: [String] = []
  211      static var saidLines: [String] = []
  212      /// Shown lines the rep partly said in their own words (a paraphrase): neither confirmed nor "never said".
  213      static var likelyCoveredLines: [String] = []
  214      /// The step of the last line the rep actually said (Opener, Discovery, Value...).
  215      static var lastSaidStage = ""
  216      /// What the last reply prompt included, for the call trace.
  217      static var lastContext: [String: Any] = [:]
  218  
  219      /// `turns` are finalized transcript only. `speculative`: `latest` is still-changing partial words
  220      /// (an early draft), so it's labeled as not final and never written into the call as fact.
  221      static func reply(turns: [Turn], latest: String, calling: String?, details: String?, style: Opener?, openTimes: String?,
  222                        speculative: Bool = false, repLed: Bool = false, assumeYes: Bool = false, fullContext: Bool = false) -> String {
  223          // Short call (12 turns or fewer, or no summary yet): every finalized turn, word for word.
  224          // Longer: the summary of everything before, plus the last 10 turns word for word.
  225          let start = fullContext ? 0 : CallMemoryRules.verbatimStart(totalTurns: turns.count, summaryCovers: summaryCoversTurns, hasSummary: !liveSummary.isEmpty)
  226          let recent = Array(turns[start...].suffix(300))
  227          var history = recent.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
  228          if recent.count < turns.count { history = "Earlier in the call (summary):\n\(liveSummary)\n\nThe last minute, word for word:\n" + history }
  229          let repLast = turns.last { $0.speaker == .rep }?.text ?? ""
  230          latestProspect = (repLed || assumeYes) ? "" : latest
  231          recentText = recent.suffix(6).map(\.text).joined(separator: " ")
  232          let intent = (repLed || assumeYes) ? ConversationIntent.other : ConversationIntent.classify(latest)
  233          let priority: String = {
  234              switch intent {
  235              case .question: return "PRIORITY NOW: they asked a direct question. MOVE answer: answer it plainly in the first sentence. No discovery question in this line.\n"
  236              case .rejection: return "PRIORITY NOW: they clearly said no. MOVE acknowledge or close. No sales question; at most offer an easy exit. After a second no, thank them and end.\n"
  237              case .objection: return "PRIORITY NOW: they raised an objection, not a refusal. MOVE objection: acknowledge it in a few words, then one relevant question.\n"
  238              case .ending, .optOut: return "PRIORITY NOW: they're ending the call. MOVE close: thank them briefly. No more questions.\n"
  239              case .other: return ""
  240              }
  241          }()
  242          lastContext = ["mode": recent.count < turns.count ? "summary + last 10 turns" : "full transcript",
  243                         "turns_total": turns.count, "turns_verbatim_from": turns.count - recent.count + 1, "turns_verbatim_to": turns.count,
  244                         "speculative_latest": speculative, "rep_led": repLed, "shown_lines_included": min(shownLines.count, 5)]
  245          let now = assumeYes
  246              ? "The rep just asked: \"\(latest)\"\nThe prospect hasn't answered. Write the line for if they say yes. If the rep asked permission to explain, this is the script's next approved pitch, said simply. If it was a discovery question, this is the follow-up to a yes."
  247              : repLed
  248              ? "The rep went off script and just said, in their own words: \"\(latest)\"\nThe prospect hasn't answered yet. Give the rep the next line that builds on what they just said."
  249              : speculative
  250              ? "The prospect is still talking. Heard so far (partial, may change, not confirmed): \"\(latest)\""
  251              : "The prospect just said: \"\(latest)\""
  252          // Facts only: what the rep said is done; a line shown but not said never reached the prospect.
  253          let said = saidLines.suffix(5).map { "- \($0)" }.joined(separator: "\n")
  254          let notSaid = shownLines.filter { !saidLines.contains($0) && !likelyCoveredLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
  255          let partly = likelyCoveredLines.filter { !saidLines.contains($0) }.suffix(3).map { "- \($0)" }.joined(separator: "\n")
  256          let shown = (said.isEmpty ? "" : "Coach lines the rep actually said (done, don't repeat):\n" + said + "\n")
  257              + (partly.isEmpty ? "" : "Coach lines the rep partly covered in their own words (likely done; don't repeat as is):\n" + partly + "\n")
  258              + (notSaid.isEmpty ? "" : "Coach lines shown but NOT said (the prospect never heard them; the rep chose their own words):\n" + notSaid + "\n")
  259              + (lastSaidStage.isEmpty ? "" : "The last step the rep actually covered: \(lastSaidStage)\n")
  260          let opened = style.map { "The rep opened with the \"\($0.name)\" opener: \($0.template)\nGood follow-up for it: \($0.followUp)\n\n" } ?? ""
  261          let booking = openTimes.map { "\($0)\n\n" } ?? ""
  262          return """
  263          \(about(calling, details))\(opened)\(booking)Call so far, oldest first:
  264          \(history)
  265  
  266          \(repLast.isEmpty ? "" : "The rep's last words: \"\(repLast)\"\n")\(now)
  267          \(blockerHints.isEmpty ? "" : "\n" + blockerHints + "\n")\(questionFacts.isEmpty ? "" : "\nQuestions on this call (tracked by simple rules from the transcript):\n" + questionFacts + "\n")\(objectionFacts.isEmpty ? "" : "\nObjections on this call (tracked by simple rules from their words; answered is not the same as resolved):\n" + objectionFacts + "\n")
  268          \(priority)\(shown)\(prospectNos == 1 ? "They have clearly said no once. No more sales questions: acknowledge it, at most offer an easy exit.\n" : "")
  269          The tracked questions and objections above come from simple rules on the transcript. If the transcript
  270          shows something different, the transcript is the truth.
  271          The rep's actual words are the truth; the script is the guide. If the rep already covered something in
  272          their own words (the reason for the call, the pitch, a question), it's done: never repeat it. Coach from
  273          where the rep really is toward the next goal of the script.
  274          If the prospect asked a question, the first sentence answers it plainly and directly.
  275          Roles: the rep is the caller from Clarity. The prospect is the person being called. Never have the rep
  276          claim the prospect's role, title or decisions ("I'm the one who decides"). If unsure who decides, ask.
  277          A pain is theirs only if they said it. Never state a problem as theirs or as what "usually" bothers teams when
  278          they haven't said it. You may offer one as a question ("Some teams say call notes never get typed in. True for you?").
  279          A clear no: acknowledge it, no sales question, at most offer an easy exit. A second no: thank them and end.
  280          An objection is not a no: acknowledge it, then one relevant question.
  281          What should the rep say next? SAY is 1 to 2 short sentences, \(LineBudget.promptMax) words at most. End with one
  282          question when the move is to learn something (discover, clarify, objection); an answer, acknowledgment or
  283          close can end plainly. Use the script's wording when a row truly fits; otherwise write what this
  284          conversation needs.
  285          """
  286      }
  287  
  288      /// Written before the call, so it's ready the instant a voicemail greeting starts.
  289      static func voicemail(calling: String?, details: String?, earlierTexts: [String] = [], earlierMessages: [String] = [],
  290                            history: String = "", localLunch: Bool = false) -> String {
  291          let local = localLunch ? LocalLunch.promptNote : ""
  292          let past = history.isEmpty ? "" : """
  293          What the rep has already done with this person:
  294          \(history)
  295  
  296          """
  297          let earlierLinkedIn = earlierMessages.isEmpty ? "" : """
  298          This will be LinkedIn message number \(earlierMessages.count + 1). LinkedIn messages already sent (oldest first):
  299          \(earlierMessages.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
  300          The new LINKEDIN MESSAGE must be clearly different from every one of these: a new angle or question and new wording.
  301  
  302          """
  303          let earlier = earlierTexts.isEmpty ? "" : """
  304          This will be text number \(earlierTexts.count + 1) to this person. Texts already sent (oldest first):
  305          \(earlierTexts.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
  306          The new TEXT must be clearly different from every one of these: a new angle or question and new wording.
  307          Don't reuse their opening words. Keep it short and friendly; later texts can be lighter (for example,
  308          a quick "should I stop reaching out?" by the 4th or 5th text).
  309  
  310          """
  311          return """
  312          \(about(calling, details))\(past)\(earlier)\(earlierLinkedIn)\(local)If this call goes to voicemail, what should the rep say after the beep?
  313          One voice for everything you write here. The voicemail, TEXT, LINKEDIN and LINKEDIN MESSAGE all come from
  314          the campaign above: its opening, its angle, its offer, its tone, and any voicemail, text or LinkedIn wording
  315          it gives. Follow the campaign over the defaults below whenever they differ.
  316          Templates come first: if the campaign or its script has a voicemail script, the voicemail is that script
  317          word for word, with only the blanks and placeholders filled in. If the campaign or its script has a text message template (a missed call text, a text
  318          after a voicemail, or any text the rep sends), the TEXT line must be that template word for word, with only
  319          the name, rep and company placeholders filled in (for a later text, use the script's matching follow-up
  320          template if it has one). Same for LinkedIn: a connection note or request template goes in LINKEDIN word for
  321          word, a LinkedIn message template goes in LINKEDIN MESSAGE, and with no LinkedIn template, use the text
  322          template there too. Only write your own when the campaign has no template. Write the voicemail first, then
  323          make every TEXT and LinkedIn line sound like the same person who just left that voicemail: the same way the
  324          rep introduces themselves (if the voicemail says something like "a fellow Portland entrepreneur", so do the
  325          text and LinkedIn note), the same reason for reaching out, the same warmth and plainness. Never switch to
  326          a different pitch or a more formal, salesy tone in the written follow-ups.
  327          Voicemail: under 20 seconds, about 40 words. In this order: their first name; the rep's name and how the
  328          campaign introduces them; one reason tied to the campaign's angle and to something specific about them,
  329          their role or their company (from the Salesforce facts, or a common pain for their title if there are none);
  330          then one closing line that fits the history above:
  331          - No text sent yet: "I'll send you a quick text so you have my number."
  332          - A text was already sent: don't promise a first text again. Mention it instead, for example
  333            "I sent you a text the other day, so you have my number" (use the real timing: today, yesterday, a few days ago).
  334          - A LinkedIn connection request or message was already sent: you can mention it, for example
  335            "I also sent you a connection request on LinkedIn" (pick the one or two most recent touches, not a list).
  336          - Voicemails were already left: don't repeat them. New angle and new wording, and it can be shorter and lighter.
  337          The TEXT, LINKEDIN and LINKEDIN MESSAGE lines below follow the same history: e.g. the text can say
  338          "left you a voicemail" or "sent you a note on LinkedIn" when that's true.
  339          No pitch, no hype, no email.
  340          CUE: one short delivery tip. STAGE: Voicemail.
  341          Then add three more lines:
  342          TEXT: <the text message to send right after. Under 40 words. Sounds like a real person texting, not marketing,
  343          and like the voicemail above. The rep introduces themselves the same way as in the voicemail, then the same
  344          reason for reaching out (the campaign's angle, tied to their role or company),
  345          then one easy yes/no question about THEIR situation (e.g. "Is that still a headache for your team?"),
  346          then one short line saying what happens next, so they know they'll hear from the rep again. Make it true to
  347          the history: calls left = "I'll try you again tomorrow if I don't hear back." or "I'll send you a note on
  348          LinkedIn too."; last call = "I won't keep calling. Reach out anytime." Vary the wording each time.>
  349          LINKEDIN: <a LinkedIn connection request note. Under 200 characters. Same voice and intro as the voicemail.
  350          Says the rep just tried calling, gives the same reason, no pitch, no links, no emojis.>
  351          LINKEDIN MESSAGE: <a LinkedIn direct message, for when they're already connected. Under 400 characters.
  352          Same voice and intro as the voicemail. Says the rep just tried calling, gives the same reason, one easy
  353          question. No links, no emojis.>
  354          Rules for the voicemail, TEXT and both LinkedIn lines:
  355          - Never name anyone they haven't met (no "Oliver", no "my partner", no "our team lead"). They only know the rep.
  356          - Don't ask for a meeting, a call length or a day in a first touch. Ask about their situation instead.
  357            Only after earlier texts or voicemails (see the history) can a later one offer a short call, and then as
  358            a simple question ("Worth a quick chat?"), still without naming anyone else.
  359          - One idea per message. No jargon, no "quick look at yours", no hype.
  360          Never copy wording from these instructions; the words come from the campaign.
  361          """
  362      }
  363  
  364      /// The Salesforce record the rep had open: the tab title and, if allowed, the page's text.
  365      private static func about(_ calling: String?, _ details: String? = nil) -> String {
  366          var lines: [String] = []
  367          let rep = Prefs.repName
  368          if !rep.isEmpty {
  369              lines.append("The rep's first name is \(rep).")
  370          }
  371          if let calling {
  372              lines.append("Salesforce record open in the rep's browser: \(calling). Use the first name if it's a person.")
  373          }
  374          if let details {
  375              lines.append("Text from their Salesforce page. It includes menus and clutter; use only facts about this person and their company, and never guess:\n\(details)")
  376          } else if calling != nil {
  377              lines.append("Assume nothing else about them.")
  378          }
  379          return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
  380      }
  381  }
  382  
```

### 2.2 Where the pieces of the user message come from

| Piece in `reply(...)` | Source | Updated |
|---|---|---|
| `about(calling, details)` | rep name (`Prefs.repName`), the Salesforce record on screen, raw page text | per call |
| "Call so far" | `turns` (final transcript). Short call: every turn word for word. Long call: `CoachPrompt.liveSummary` + last 10 turns | each request |
| "The rep's last words" | last Rep turn | each request |
| "The prospect just said" / partial / rep-led / assumeYes | the `latest` argument and mode flags | each request |
| `blockerHints` | `BlockerBook.hints` (objections this rep keeps hitting) | call start |
| `questionFacts` | `QuestionTracker.promptText` | each final turn |
| `objectionFacts` | `ObjectionTracker.promptText` | each final turn |
| `priority` | `ConversationIntent.classify(latest)` | each request |
| shown / said / partly-said lines | `CoachPrompt.shownLines`, `saidLines`, `likelyCoveredLines` | as lines show / are delivered |
| "They have said no once" | `CoachPrompt.prospectNos` | per no |


### 2.3 A user message assembled from the code (reconstructed, not captured)

The Nov 20 trace you pasted contains the activity log only, not the raw request bodies, so this is what `reply(...)` produces for the turn at 10:03:33 ("Are you the one that decides on those types of things?"), written by hand from the template above. Real bodies are in the call trace file (section 12).

```text
The rep's first name is Mason.
Salesforce record open in the rep's browser: (none: the call was placed from the phone, not from a record).
Assume nothing else about them.

Call so far, oldest first:
Prospect: Hello?
Rep: Hi. This is, my name is Mason. I'm with Clarity Consulting. I know you weren't expecting my call, but can I get thirty seconds to tell you why I called?
Prospect: What kind of car I mean? You... What is this about? What is this called about? This is called out.
Rep: Sorry. Yeah. We we do free health checks for how your teams log calls and use AI.

The rep's last words: "Sorry. Yeah. We we do free health checks for how your teams log calls and use AI."
The prospect just said: "Are you the one that decides on those types of things?"

Questions on this call (tracked exactly, trust these):
Prospect questions NOT yet answered (answer these first): "Are you the one that decides on those types of things?"

PRIORITY NOW: they asked a direct question. MOVE answer: answer it plainly in the first sentence. No discovery question in this line.
Coach lines the rep actually said (done, don't repeat):
- (the opener)
The last step the rep actually covered: Opener

The rep's actual words are the truth; the script is the guide. If the rep already covered something in
their own words ... [the closing block from CoachPrompt.reply, lines 233-252]
```

*The `PRIORITY NOW` line and the `Roles:` / `Decide in this order:` paragraph are the additions from the Nov 20 fixes; on the Nov 20 call itself the model received the same message without them.*

## 3. What Claude returns

The format is defined at the end of the system message (see `CoachPrompt.swift`, the block starting `Answer in exactly this format`):

```text
MOVE: <answer, clarify, discover, acknowledge, objection, close or silent>
STAGE: <Opener | Screener | Gatekeeper | Voicemail | Discovery | Value | Objection | Closing | Goal reached | Exit>
THINK: <one quick coaching nudge, usually 5 to 12 simple words>      (only when THINK mode is on, the default)
SAY: <the line the rep should say next>
CUE: <why, or how to say it, under 10 words>
```
For `silent`, only `MOVE: silent`. A script-row answer starts its CUE with the row id in brackets, for example `[S5 manual 2] then ask how long`; `Suggestion.rowTag` reads that and marks the line EXACT.

Output limits: `maxTokens = 120`, effort `low`, thinking disabled (`LiveCoach.client`, section 11). The parser (`Suggestion.parse`) is line-oriented so SAY can render while it streams. THINK is parsed but has no completeness flag of its own: the card only uses it once SAY is complete.


`ClarityLiveCoach/CoachTypes.swift` lines 6–80

```swift
    6  struct Suggestion: Equatable {
    7      var say = ""
    8      var cue = ""
    9      var stage = ""
   10      var skip = false
   11      /// True once the SAY line is fully written (a line break came after it, or the answer ended).
   12      var sayComplete = false
   13      /// Codes of the meeting times this line offers or confirms, e.g. ["T3", "T5"].
   14      var offered: [String] = []
   15      /// The move Claude picked before writing the line (answer, clarify, discover...).
   16      var move = ""
   17      /// THINK mode only: one short thought for the card (empty when the mode is off).
   18      var think = ""
   19      /// Voicemail follow-ups: a text to send and a LinkedIn connection note.
   20      var textMessage = ""
   21      var linkedin = ""
   22      var linkedinMessage = ""
   23      /// Phone tree: the keys to press now (0-9, * and #), for the one-click button.
   24      var keys = ""
   25      /// A nudge from the app ("Still with me?"), not a script line: shown softer.
   26      var nudge = false
   27  
   28      /// The script row this line came from, when the cue starts with one: "[S5 manual 2] ..." -> "S5 manual 2".
   29      var rowTag: String? {
   30          guard cue.hasPrefix("["), let close = cue.firstIndex(of: "]") else { return nil }
   31          let tag = cue[cue.index(after: cue.startIndex)..<close].trimmingCharacters(in: .whitespaces)
   32          return tag.isEmpty || tag.count > 24 ? nil : tag
   33      }
   34  
   35      /// The cue without the row tag in front.
   36      var cueText: String {
   37          guard rowTag != nil, let close = cue.firstIndex(of: "]") else { return cue }
   38          return cue[cue.index(after: close)...].trimmingCharacters(in: .whitespaces)
   39      }
   40  
   41      /// Claude answers in a tiny line format so words can show while they stream:
   42      ///   SAY: ...
   43      ///   CUE: ...
   44      ///   STAGE: ...
   45      ///   OFFERED: T3, T5   (only when the line offers meeting times)
   46      /// or SKIP when the rep needs no help.
   47      static func parse(_ text: String) -> Suggestion {
   48          var s = Suggestion()
   49          for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
   50              let trimmed = line.trimmingCharacters(in: .whitespaces)
   51              if let m = Move.parse(trimmed) {
   52                  s.move = m.rawValue
   53                  if m == .silent { s.skip = true } // the rep doesn't need a new line
   54                  continue
   55              }
   56              if trimmed.hasPrefix("THINK:") {
   57                  s.think = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
   58                  continue
   59              }
   60              if trimmed.hasPrefix("SAY:") {
   61                  s.say = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
   62                  continue
   63              }
   64              if !s.say.isEmpty { s.sayComplete = true } // any line after SAY means SAY is done
   65              if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
   66              else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
   67              else if trimmed.hasPrefix("SKIP") { s.skip = true }
   68              else if trimmed.hasPrefix("TEXT:") { s.textMessage = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
   69              else if trimmed.hasPrefix("KEYS:") {
   70                  s.keys = String(trimmed.dropFirst(5).filter { "0123456789*#".contains($0) }.prefix(12))
   71              }
   72              else if trimmed.hasPrefix("LINKEDIN MESSAGE:") { s.linkedinMessage = String(trimmed.dropFirst(17)).trimmingCharacters(in: .whitespaces) }
   73              else if trimmed.hasPrefix("LINKEDIN:") { s.linkedin = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
   74              else if trimmed.hasPrefix("OFFERED:") {
   75                  s.offered = trimmed.dropFirst(8).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
   76              }
   77          }
   78          return s
   79      }
   80  }
```

## 4. Generating, checking and repairing a line (`CoachModel+Lines.swift`)

Functions in the order a line passes through them. Line numbers are in each excerpt's header.

### 4.1 `scheduleEarlyStart`: the early draft

`ClarityLiveCoach/CoachModel+Lines.swift` lines 182–216

```swift
  182      /// If the prospect's words end like a finished sentence and hold still for a moment,
  183      /// start Claude now instead of waiting for the end-of-speech signal.
  184      func scheduleEarlyStart() {
  185          specTimer?.cancel()
  186          guard status == .live, !screenerActive, !voicemailActive, !doNotCall else { return } // prepare even while a line is up
  187          let text = (uncoached + " " + (interim[.prospect] ?? "")).trimmed
  188          if pendingAmbiguousOptOut != nil, !(interim[.prospect] ?? "").isEmpty { armPendingOptOutTimer() } // still talking: wait more
  189          if pendingAmbiguousOptOut != nil || OptOut.hasAmbiguous(text) { return } // never draft on a possible opt-out (Fix 3)
  190          // "Don't call me back" mid-sentence: stop selling now, don't wait for them to finish.
  191          if LiveCoach.isOptOut(text, isFinal: false) { handleOptOut(text); return }
  192          guard isMeaningful(text) else { return }
  193          // A script answer waits for their full sentence ("I don't know..." can end "...that I'm the right fit"):
  194          // the final words go through the same priority checks.
  195          if scriptAnswers.matchInContext(text, answeredQuestions: CoachPrompt.answeredQuestions).entry != nil { return }
  196          // Draft early once their meaning is clear: a finished sentence (200 ms), or 6+ words that
  197          // stopped changing (450 ms). Each new word cancels the wait, so there's no flood of requests.
  198          // A yes to the rep's question, with the yes line already written: no draft needed.
  199          if yesBranch != nil, ProspectReply.kind(text) == .yes { return } // ready or still being written
  200          // One or two word fragments ("No.") almost always grow: drafting on them wastes a request.
  201          guard let wait = EarlyStart.delayMS(for: text),
  202                EarlyStart.shouldRedraft(previous: lastEarlyBasis, text: text, draftsThisTurn: earlyDraftsThisTurn) else { return }
  203          specTimer = Task { [weak self] in
  204              try? await Task.sleep(for: .milliseconds(wait))
  205              guard let self, !Task.isCancelled, !self.doNotCall,
  206                    EarlyStart.shouldRedraft(previous: self.lastEarlyBasis, text: text, draftsThisTurn: self.earlyDraftsThisTurn),
  207                    (self.uncoached + " " + (self.interim[.prospect] ?? "")).trimmed == text,
  208                    normalized(text) != self.specBasis else { return }
  209              self.ask(.reply, user: CoachPrompt.reply(
  210                  turns: self.turns, latest: text, calling: self.calling, details: self.recordDetails, style: self.callOpener,
  211                  openTimes: self.bookingText(), speculative: true
  212              ), early: text)
  213              self.lastEarlyBasis = text
  214              self.earlyDraftsThisTurn += 1
  215          }
  216      }
```

### 4.2 `prospectFinished`: everything that can happen when the prospect stops (opt-out, no's, yes branch, instant answer, ask)

`ClarityLiveCoach/CoachModel+Lines.swift` lines 218–392

```swift
  218      /// The prospect stopped talking. Decide if the rep needs a new line.
  219      func prospectFinished() {
  220          specTimer?.cancel()
  221          lastEarlyBasis = nil
  222          earlyDraftsThisTurn = 0
  223          if goalPending, !goalHit { // once per full turn, not per chunk (Fix 5)
  224              goalPendingTurns = GoalPendingRule.turnsLeft(after: goalPendingTurns, confirmed: false)
  225              if goalPendingTurns <= 0 { goalPending = false }
  226          }
  227          var said = uncoached.trimmingCharacters(in: .whitespaces)
  228          // A possible opt-out is waiting: decide it first, with whatever they said after it (Fix 1c).
  229          if let pendingSaid = pendingAmbiguousOptOut {
  230              let outcome = PendingOptOut.resolve(pending: pendingSaid, later: said, utteranceEnded: false, callEnded: false,
  231                                                  secondsWaited: Date().timeIntervalSince(pendingAmbiguousAt))
  232              if outcome != .wait {
  233                  pendingAmbiguousOptOut = nil
  234                  pendingOptOutTask?.cancel()
  235                  if outcome == .optOut { handleOptOut((pendingSaid + " " + said).trimmingCharacters(in: .whitespaces)); return }
  236                  said = (pendingSaid + " " + said).trimmingCharacters(in: .whitespaces) // a callback request: answer it as one
  237                  CallTrace.event("optout.not", ["said": said, "why": "a later time followed: a callback request"])
  238              }
  239          }
  240          guard !said.isEmpty else { return }
  241          if doNotCall {
  242              uncoached = ""
  243              CallTrace.event("coach.suppressed", ["said": said, "why": "do not call: no more sales lines this call"])
  244              return
  245          }
  246          if status == .live, LiveCoach.isOptOut(said, isFinal: false) { handleOptOut(said); return } // clear phrases
  247          // Hold only if no later time already follows; "...until Tuesday" is a callback and gets a normal answer.
  248          if status == .live, OptOut.hasAmbiguous(said), OptOut.matches(said, isFinal: true) {
  249              // "Don't call me back..." might go on ("...until Tuesday"). No sales line; decide at the full pause.
  250              pendingAmbiguousOptOut = said
  251              pendingAmbiguousAt = Date()
  252              CallTrace.event("optout.waiting", ["said": said, "why": "might be a callback request; waiting for the full pause"])
  253              uncoached = ""
  254              armPendingOptOutTimer()
  255              return
  256          }
  257          if phoneTreeActive { uncoached = ""; askPhoneTree(); return } // the menu goes on: re-plan the route
  258          // Two no's and a go: count their no's; two (or a no plus "yep, thanks") ends it politely, no AI.
  259          if status == .live, prospectNos > 0 { prospectTurnsAfterFirstNo += 1 }
  260          if status == .live, !voicemailActive, Rejection.isNo(said) { prospectNos += 1 }
  261          if status == .live, !voicemailActive, Rejection.callOver(nosSoFar: prospectNos, latest: said), !callClosed {
  262              callClosed = true
  263              closedOnSecondNo = prospectNos >= 2
  264              uncoached = ""
  265              coachTask?.cancel(); specTimer?.cancel(); pending = nil; yesBranch = nil; yesBranchTask?.cancel()
  266              let first = Screener.firstName(calling) ?? ""
  267              seq += 1
  268              CallTrace.event("call.closing", ["said": said, "nos": prospectNos, "why": "two no's, or a no and a sign-off"])
  269              show(Suggestion(say: "Totally understand\(first.isEmpty ? "" : ", \(first)"). Thanks for your time. Have a good one.",
  270                              cue: "Two no's: end it kindly.", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
  271              return
  272          }
  273          if callClosed { uncoached = ""; return } // nothing more to sell on this call
  274          if voicemailActive { uncoached = ""; return } // no coaching while a greeting plays
  275          // The rep asked a yes/no question and the line for "yes" is ready: a clear yes shows it now,
  276          // with no wait. No, unsure, or anything else gets a fresh answer from their real words.
  277          // Too old: the talk moved on since the question. Drop it and answer fresh.
  278          if yesBranch != nil, !YesBranchRule.usable(ageSinceQuestion: Date().timeIntervalSince(yesBranchAskedAt)) {
  279              CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "expired"])
  280              yesBranch = nil; yesBranchTask?.cancel()
  281          }
  282          if let yb = yesBranch, !yb.ready, ProspectReply.kind(said) == .yes {
  283              yesBranchWanted = said // nearly done: use it when it lands instead of starting over (H3)
  284              // ...but never dead air: after 1.2 s, give up on it and answer from their words.
  285              let waitFor = yb.question
  286              Task { [weak self] in
  287                  try? await Task.sleep(for: .seconds(YesBranchRule.maxWait))
  288                  guard let self, self.yesBranchWanted == said, self.yesBranch?.question == waitFor else { return }
  289                  self.yesBranchWanted = nil
  290                  self.yesBranch = nil
  291                  self.yesBranchTask?.cancel()
  292                  CallTrace.event("yes_branch.discarded", ["question": waitFor, "why": "not ready within \(YesBranchRule.maxWait) s"])
  293                  self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
  294                                                           details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
  295              }
  296              specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
  297              uncoached = ""
  298              latestProspect = said
  299              CallTrace.event("yes_branch.waiting", ["question": yb.question, "answer": said])
  300              return
  301          }
  302          if let yb = yesBranch {
  303              yesBranch = nil
  304              yesBranchTask?.cancel()
  305              let kind = ProspectReply.kind(said)
  306              if kind == .yes, yb.ready {
  307                  // A short wait so "Yeah. ...No, I'm not interested." can cancel it (call 6).
  308                  specTimer?.cancel(); specBasis = nil; specHeld = nil; coachTask?.cancel()
  309                  uncoached = ""
  310                  latestProspect = said
  311                  let line = yb.s
  312                  yesShowTask?.cancel()
  313                  yesShowTask = Task { [weak self] in
  314                      try? await Task.sleep(for: .milliseconds(600))
  315                      guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall, !self.callClosed,
  316                            !self.voicemailActive, !self.screenerActive,
  317                            self.uncoached.trimmingCharacters(in: .whitespaces).isEmpty,
  318                            (self.interim[.prospect] ?? "").isEmpty else {
  319                          CallTrace.event("yes_branch.discarded", ["question": yb.question, "why": "they kept talking after the yes"])
  320                          return
  321                      }
  322                      CallTrace.event("yes_branch.used", ["question": yb.question, "answer": said, "line": line.say])
  323                      ActivityLog.add("Coach: they said yes, ready line shown")
  324                      self.markRequestStart()
  325                      self.seq += 1
  326                      self.offer(line, id: self.seq, kind: .reply, askedAt: Date())
  327                  }
  328                  return
  329              }
  330              CallTrace.event("yes_branch.discarded", ["question": yb.question, "answer": said, "answer_kind": kind.rawValue,
  331                                                       "ready": yb.ready, "why": kind == .yes ? "not ready yet" : "their answer wasn't a clear yes"])
  332          }
  333  
  334          // Started early on exactly these words? Then the answer is already on its way.
  335          if let basis = specBasis {
  336              specBasis = nil
  337              if basis != normalized(said) {
  338                  // Thrown out: stop it now, so it can't show later on any early return below (C5).
  339                  coachTask?.cancel(); specHeld = nil; thinking = false
  340                  CallTrace.event("early.wasted", ["basis": basis, "said": said, "why": "they kept talking after the early draft started"])
  341              }
  342              if basis == normalized(said) {
  343                  CallTrace.event("early.used", ["basis": basis, "said": said, "why": "their final words matched the early draft"])
  344                  uncoached = ""
  345                  latestProspect = said
  346                  confirmedAt = Date()
  347                  if let held = specHeld {
  348                      specHeld = nil
  349                      offer(held.s, id: held.id, kind: .reply, askedAt: confirmedAt!)
  350                  }
  351                  return
  352              }
  353          }
  354          if screenerActive {
  355              uncoached = ""
  356              if Screener.detects(said) { return } // still the screener talking
  357              // A real person picked up after the screener: back to the opener.
  358              screenerActive = false
  359              attempt?.screenerEnded(personSaid: said)
  360              latestProspect = said
  361              if let opener = openerBeforeScreener {
  362                  // Not on the mutual "Hello?": wait for 0.8 s of quiet, so the rep isn't reading over the greeting.
  363                  openerWaitTask?.cancel()
  364                  openerWaitTask = Task { [weak self] in
  365                      try? await Task.sleep(for: .milliseconds(800))
  366                      guard let self, !Task.isCancelled, self.status == .live, !self.doNotCall,
  367                            (self.interim[.prospect] ?? "").isEmpty, self.uncoached.isEmpty else { return }
  368                      self.seq += 1
  369                      self.show(opener, id: self.seq, kind: .opener)
  370                  }
  371                  return
  372              }
  373          }
  374          // Always prepare an answer. Whether it shows now or waits is the display controller's call
  375          // (CoachMachine.canReplace): the line being read is never swapped out from under the rep.
  376          uncoached = ""
  377          latestProspect = said
  378          // A plain "Hello?" is already answered by the opener on screen.
  379          let onlyGreeting = kind == .opener && turns.count <= 1 && said.split(separator: " ").count <= 4
  380          // "Sure" or "Yes" is filler while the rep talks, but a real answer to the rep's question.
  381          let repAsked = turns.last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
  382          guard !onlyGreeting, isMeaningful(said) || repAsked || turns.count <= 2 else {
  383              CallTrace.event("coach.skipped", ["said": said, "why": onlyGreeting ? "a plain greeting; the opener already answers it" : "not meaningful (filler)"])
  384              return
  385          }
  386          if instantAnswer(said) { return }
  387          ask(.reply, user: CoachPrompt.reply(
  388              turns: turns, latest: said, calling: calling, details: recordDetails, style: callOpener,
  389              openTimes: bookingText()
  390          ))
  391          updateSummaryIfDue()
  392      }
```

### 4.3 `ask`: building the request, streaming, the first check

`ClarityLiveCoach/CoachModel+Lines.swift` lines 508–612

```swift
  508      func ask(_ kind: Kind, user: String, early: String? = nil) {
  509          guard let key = Keychain.read(.anthropic) else {
  510              problem = "Add your Anthropic key: gear > Setup > AI keys."
  511              return
  512          }
  513          if doNotCall, kind == .reply {
  514              CallTrace.event("claude.blocked", ["why": "do not call", "early": early != nil])
  515              return
  516          }
  517          coachTask?.cancel() // a newer statement makes the old answer stale
  518          if kind == .reply { repWordsAtLastAsk = repWordsInCall; repTextSinceAsk = "" }
  519          let repLed = nextIsRepLed
  520          nextIsRepLed = false
  521          seq += 1
  522          let id = seq
  523          if repLed { repLedIDs.insert(id) }
  524          let askedAt = Date()
  525          logSystemIfChanged()
  526          CallTrace.event("memory.snapshot", ["summary": CoachPrompt.liveSummary, "summary_version": CallTrace.memVersion,
  527                                              "question_facts": CoachPrompt.questionFacts, "objection_facts": CoachPrompt.objectionFacts, "blocker_hints": CoachPrompt.blockerHints,
  528                                              "turns": turns.count], req: id)
  529          let override = kind == .reply ? nextAskModel : nil // a space-bar fresh line uses Sonnet
  530          nextAskModel = nil
  531          let requested = (kind == .reply ? LiveCoach.client(key, model: override) : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)).model
  532          if kind == .reply { ActivityLog.add("Coach #\(id): asking \(ClaudeClient.displayName(requested))\(early == nil ? "" : " early, from their words so far")") }
  533          else { ActivityLog.add("Coach #\(id): \(kind) from \(ClaudeClient.displayName(requested))") }
  534          CallTrace.event("claude.request", [
  535              "kind": "\(kind)", "early": early != nil, "early_basis": early ?? "",
  536              "system_chars": self.system.count, "system_hash": Self.stableHash(self.system),
  537              "user_message": user, "summary_version": CallTrace.memVersion,
  538              "context": kind == .reply ? CoachPrompt.lastContext : [:], "user_chars": user.count,
  539          ], req: id)
  540          specBasis = early.map(normalized)
  541          specHeld = nil
  542          confirmedAt = nil
  543          // Live lines: Haiku, short and fast. Voicemails also Haiku, so the message is ready before the beep.
  544          let client = kind == .reply ? LiveCoach.client(key, model: override)
  545              : (kind == .voicemail ? CoachSpeed.fastest : CoachSpeed.current).client(apiKey: key)
  546          let system = self.system
  547          thinking = true
  548          CallTrace.event("claude.settings", ["model": client.model, "max_tokens": client.maxTokens, "effort": client.effort,
  549                                              "thinking": client.thinking?["type"] ?? "default", "stream": true,
  550                                              "idle_timeout_s": client.idleTimeout, "total_timeout_s": client.totalTimeout], req: id)
  551  
  552          coachTask = Task { [weak self] in
  553              do {
  554                  var finalText = ""
  555                  let gate = LineGate()
  556                  let started = Date()
  557                  var firstToken = false
  558                  try await client.stream(system: system, user: user, onText: { text in
  559                      if !firstToken, kind == .reply {
  560                          firstToken = true
  561                          ActivityLog.add("Coach #\(id): first words from Claude after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
  562                          let ms = Int(Date().timeIntervalSince(started) * 1000)
  563                          Task { @MainActor in CallTrace.event("claude.first_token", ["ms": ms], req: id) }
  564                      }
  565                      finalText = text
  566                      let s = Suggestion.parse(text)
  567                      Task { @MainActor in
  568                          guard kind == .reply else { self?.offer(s, id: id, kind: kind, askedAt: askedAt); return }
  569                          // A live line shows only once it's whole and passes the house rules.
  570                          guard (s.sayComplete && !s.stage.isEmpty) || s.skip, !gate.checked else { if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }; return }
  571                          gate.checked = true
  572                          let problems = s.skip ? [] : Self.lineProblems(s)
  573                          gate.passed = problems.isEmpty
  574                          CallTrace.event("check.result", ["stage": "stream", "line": s.say, "skip": s.skip,
  575                                                           "passed": gate.passed, "problems": problems], req: id)
  576                          if gate.passed { self?.offer(s, id: id, kind: kind, askedAt: askedAt) }
  577                      }
  578                  }, onUsage: { u in
  579                      // Token counts and cache use: cache_read > 0 means the system prompt came from cache.
  580                      Task { @MainActor in CallTrace.event("claude.usage", u.merging(["ms": Int(Date().timeIntervalSince(started) * 1000)]) { a, _ in a }, req: id) }
  581                  }, onModel: { served in
  582                      guard served != requested, !served.hasPrefix(requested) else { return }
  583                      Task { @MainActor in
  584                          ActivityLog.add("Coach #\(id): model switched: asked \(ClaudeClient.displayName(requested)), answered by \(ClaudeClient.displayName(served)) (fallback)")
  585                          CallTrace.event("claude.model_switch", ["requested": requested, "served": served], req: id)
  586                      }
  587                  })
  588                  if kind == .reply { ActivityLog.add("Coach #\(id): Claude done after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
  589                  CallTrace.event("claude.done", ["ms": Int(Date().timeIntervalSince(started) * 1000), "output": finalText,
  590                                                  "fresh": self?.seq == id], req: id)
  591                  var last = Suggestion.parse(finalText)
  592                  last.sayComplete = true
  593                  if kind == .reply, !last.skip, !last.say.isEmpty {
  594                      let problems = Self.lineProblems(last)
  595                      CallTrace.event("check.result", ["stage": "final", "line": last.say, "passed": problems.isEmpty,
  596                                                       "problems": problems], req: id)
  597                      if !problems.isEmpty { last = await self?.fixLine(last, system: system, user: user, key: key, id: id) ?? last }
  598                  }
  599                  self?.offer(last, id: id, kind: kind, askedAt: askedAt)
  600              } catch is CancellationError {
  601                  CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
  602              } catch let error as URLError where error.code == .cancelled {
  603                  CallTrace.event("claude.cancelled", ["why": "a newer request replaced it"], req: id)
  604              } catch {
  605                  CallTrace.event("claude.error", ["error": error.localizedDescription], req: id)
  606                  // Keep the last good line on screen; just flag it.
  607                  self?.problem = "Coach hiccup: \(error.localizedDescription)"
  608                  ActivityLog.problem("Claude error: \(error.localizedDescription)")
  609              }
  610              if self?.seq == id { self?.thinking = false }
  611          }
  612      }
```

### 4.4 `lineProblems`: the checks a line must pass

`ClarityLiveCoach/CoachModel+Lines.swift` lines 614–639

```swift
  614      /// The house rules for a live line (offered meeting times are allowed).
  615      static func lineProblems(_ s: Suggestion) -> [String] {
  616          // A question is required only when the move is to learn something: answer, acknowledge and close may end plainly.
  617          let plainEnding = ["answer", "acknowledge", "close"].contains(s.move)
  618          var p = Guardrail.problems(s.say, endsCall: ["Exit", "Goal reached", "Voicemail"].contains(s.stage) || s.rowTag != nil || plainEnding, allowTimes: true)
  619          // The conversation outranks the stage (Nov 20).
  620          if RoleCheck.speaksAsProspect(s.say) {
  621              p.append("the rep claims the prospect's role: the rep is the caller, never the one who decides there")
  622          }
  623          let intent = ConversationIntent.classify(CoachPrompt.latestProspect)
  624          if s.move == "discover", intent == .question {
  625              p.append("they asked a direct question: answer it plainly first (MOVE answer), no discovery question")
  626          }
  627          if ["discover", "clarify", "objection"].contains(s.move), intent == .rejection {
  628              p.append("they declined: a clear no gets no sales question (MOVE acknowledge or close)")
  629          }
  630          // THINK is the coaching: a normal live line needs a useful one, checked against this conversation.
  631          if Think.enabled, s.rowTag == nil, !s.nudge, !s.skip {
  632              p.append(contentsOf: Think.problems(think: s.think, say: s.say, move: s.move, intent: intent,
  633                                                  objectionKind: ObjectionTracker.detect(CoachPrompt.latestProspect),
  634                                                  latestProspect: CoachPrompt.latestProspect, recentText: CoachPrompt.recentText,
  635                                                  scriptText: CoachPrompt.scriptText, answeredQuestions: CoachPrompt.answeredQuestions))
  636          }
  637          // A script row copied word for word ("S2 open" is 26 words) isn't sent back for being long.
  638          return s.rowTag == nil ? p : p.filter { !$0.contains("words (max") }
  639      }
```

### 4.5 `fixLine`: repair (code fix, one retry on the call's model, then trim or drop)

`ClarityLiveCoach/CoachModel+Lines.swift` lines 651–703

```swift
  651      /// A line broke the rules: Haiku tries again with the reasons, then Sonnet, then the smallest safe fix.
  652      func fixLine(_ bad: Suggestion, system: String, user: String, key: String, id: Int = 0) async -> Suggestion {
  653          var problems = Self.lineProblems(bad)
  654          ActivityLog.add("Line check: failed (\(problems.joined(separator: "; "))): \(bad.say)")
  655          CallTrace.event("check.fail", ["line": bad.say, "problems": problems], req: id)
  656          // Formatting only (an abbreviation like CRM, an em dash): fix it in code, no second request.
  657          if problems.allSatisfy({ $0.hasPrefix("abbreviation") || $0 == "em dash" || $0 == "more than one question" }),
  658             let fixed = LineRepair.fix(bad.say) {
  659              var s = bad
  660              s.say = fixed
  661              // Spelled-out words add syllables: allow half a grade of slack on a repaired line (M6).
  662              let left = Self.lineProblems(s).filter { !($0.hasPrefix("reading level") && ReadingLevel.grade(fixed) <= ReadingLevel.checkMax + 0.5) }
  663              if left.isEmpty {
  664                  ActivityLog.add("Line check: fixed in code (no extra request)")
  665                  CallTrace.event("check.fixed_locally", ["from": bad.say, "line": fixed], req: id)
  666                  return s
  667              }
  668          }
  669          for model in [LiveCoach.callModel] { // one retry at most, on this call's model (H4)
  670              var text = ""
  671              let retry = user + "\n\nYour last answer broke these rules: \(problems.joined(separator: "; ")). THINK was: \"\(bad.think)\". SAY was: \"\(bad.say)\". Write MOVE, STAGE, THINK, SAY and CUE again."
  672              CallTrace.event("claude.retry.request", ["model": model, "user_message": retry], req: id)
  673              let t0 = Date()
  674              ActivityLog.add("Line check: asking \(ClaudeClient.displayName(model)) to fix it")
  675              try? await LiveCoach.client(key, model: model).stream(system: system, user: retry) { text = $0 }
  676              var s = Suggestion.parse(text)
  677              s.sayComplete = true
  678              let left = s.skip ? [] : Self.lineProblems(s)
  679              CallTrace.event("claude.retry.done", ["model": model, "ms": Int(Date().timeIntervalSince(t0) * 1000), "output": text,
  680                                                    "passed": !s.say.isEmpty && left.isEmpty, "problems": left], req: id)
  681              if s.skip || (!s.say.isEmpty && Self.lineProblems(s).isEmpty) {
  682                  ActivityLog.add("Line check: fixed by \(model.contains("haiku") ? "Haiku" : "Sonnet")")
  683                  CallTrace.event("check.fixed", ["model": model, "line": s.say], req: id)
  684                  return s
  685              }
  686              if !s.say.isEmpty { problems = Self.lineProblems(s) }
  687          }
  688          // Final check. Formatting (length, an abbreviation, the question mark) can be trimmed safely. A wrong move,
  689          // a role mix-up, or a THINK that doesn't fit the conversation can't: show nothing new instead.
  690          if Self.lineProblems(bad).contains(where: Self.isSerious) {
  691              var quiet = bad
  692              quiet.skip = true
  693              quiet.move = "silent"
  694              ActivityLog.add("Line check: dropped (wrong move for the conversation): \(bad.say)")
  695              CallTrace.event("check.dropped", ["line": bad.say, "problems": Self.lineProblems(bad)], req: id)
  696              return quiet
  697          }
  698          var s = bad
  699          s.say = LiveCoach.sanitize(bad.say)
  700          ActivityLog.add("Line check: trimmed to fit: \(s.say)")
  701          CallTrace.event("check.trimmed", ["line": s.say, "from": bad.say], req: id)
  702          return s
  703      }
```

### 4.6 `Guardrail.problems`: house rules applied to every line

`ClarityLiveCoach/Guardrail.swift` lines 18–49

```swift
   18      /// What's wrong with a line, or [] if it's fine.
   19      /// - long: voicemails, texts and LinkedIn notes may run past 25 words.
   20      /// - endsCall: the row ends the call, so it needn't end with a question.
   21      static func problems(_ line: String, long: Bool = false, endsCall: Bool = false, allowTimes: Bool = false) -> [String] {
   22          let say = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
   23          guard !say.isEmpty, !say.lowercased().hasPrefix("show nothing") else { return [] }
   24          var out: [String] = []
   25          let words = say.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
   26          if !long, words > LineBudget.checkMax { out.append("\(words) words (max \(LineBudget.checkMax))") }
   27          let questions = say.filter { $0 == "?" }.count
   28          if !long, questions > 1 { out.append("more than one question") }
   29          if !long, !endsCall, !say.hasSuffix("?") { out.append("doesn't end with a question") }
   30          // All-caps abbreviations, except AI and [slots].
   31          let noSlots = say.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
   32          let caps = noSlots.matches(#"\b[A-Z]{2,}\b"#).filter { $0 != "AI" }
   33          if !caps.isEmpty { out.append("abbreviation: " + caps.joined(separator: ", ")) }
   34          let lower = say.lowercased()
   35          let hits = banned.filter { lower.contains($0) }
   36          if !hits.isEmpty { out.append("banned: " + hits.joined(separator: ", ")) }
   37          if say.contains("$") || say.contains("%") || lower.range(of: #"\d+\s*(dollar|percent)"#, options: .regularExpression) != nil {
   38              out.append("money or percent")
   39          }
   40          if say.contains("\u{2014}") { out.append("em dash") }
   41          let grade = ReadingLevel.grade(noSlots)
   42          if grade > ReadingLevel.checkMax {
   43              out.append(String(format: "reading level grade %.1f (max %.0f): use shorter words and sentences", grade, ReadingLevel.target))
   44          }
   45          let timeLike = lower.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#, options: .regularExpression) != nil
   46          if !allowTimes, timeLike || days.contains(where: { noSlots.lowercased().contains($0) }) { out.append("a made-up day or time (use [Slot A])") }
   47          if lower.contains("show the") || lower.contains("show s") { out.append("an instruction, not a real line") }
   48          return out
   49      }
```

### 4.7 `LineRepair` and `LineBudget`: code-only fixes and the word limits

`CoachCore/CoachCore.swift` lines 324–329

```swift
  324  /// Live line length. The prompt asks for fewer words than the check allows, so a line that runs a
  325  /// word long passes instead of costing a second fixing it.
  326  public enum LineBudget {
  327      public static let checkMax = 25
  328      public static let promptMax = 20
  329  }
```

`CoachCore/CoachCore.swift` lines 792–843

```swift
  792  /// Small, safe fixes done in code, so a line isn't sent back to Claude (about a second) for formatting.
  793  public enum LineRepair {
  794      public static let abbreviations: [String: String] = [
  795          "CRM": "customer system", "ROI": "return", "SDR": "rep", "SDRs": "reps", "BDR": "rep", "BDRs": "reps",
  796          "AE": "account rep", "AEs": "account reps", "KPI": "goal", "KPIs": "goals", "RevOps": "revenue team",
  797          "SaaS": "software", "B2B": "business", "ASAP": "soon", "FYI": "just so you know",
  798      ]
  799  
  800      /// The line with known abbreviations spelled out and em dashes turned to commas, or nil if an
  801      /// all-caps word we don't know is left (that one still goes back to Claude).
  802      public static func fix(_ line: String) -> String? {
  803          var out = line.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
  804          out = oneQuestion(out)
  805          for (abbr, plain) in abbreviations {
  806              out = out.replacingOccurrences(of: "\\b\(abbr)\\b", with: plain, options: .regularExpression)
  807          }
  808          let leftover = out.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 && $0.allSatisfy(\.isUppercase) && $0 != "AI" }
  809          return leftover.isEmpty ? out : nil
  810      }
  811  
  812      /// "Makes sense? How many reps?" -> "Makes sense. How many reps?": only the last question keeps its "?" (H4).
  813      public static func oneQuestion(_ line: String) -> String {
  814          guard let last = line.lastIndex(of: "?") else { return line }
  815          var out = ""
  816          for (i, ch) in zip(line.indices, line) { out.append(ch == "?" && i != last ? "." : ch) }
  817          return out
  818      }
  819  
  820      /// Fit a long line to `max` words without leaving a fragment (M7): keep the trailing question if it
  821      /// fits, else whole sentences from the start, else the first `max` words.
  822      public static func trimToFit(_ line: String, max: Int) -> String {
  823          let words = line.split(separator: " ")
  824          guard words.count > max else { return line }
  825          let sentences = line.split(omittingEmptySubsequences: true, whereSeparator: { ".!?".contains($0) })
  826          var ends: [String] = []
  827          var rest = Substring(line)
  828          for s in sentences {
  829              guard let r = rest.range(of: s) else { break }
  830              let after = rest[r.upperBound...]
  831              let punct = after.prefix(while: { ".!?".contains($0) })
  832              ends.append((s + punct).trimmingCharacters(in: .whitespaces))
  833              rest = after.dropFirst(punct.count)
  834          }
  835          if let q = ends.last, q.hasSuffix("?"), q.split(separator: " ").count <= max { return q }
  836          var kept: [String] = []
  837          for s in ends {
  838              if (kept + [s]).joined(separator: " ").split(separator: " ").count > max { break }
  839              kept.append(s)
  840          }
  841          return kept.isEmpty ? words.prefix(max).joined(separator: " ") : kept.joined(separator: " ")
  842      }
  843  }
```

### 4.8 `offer` and `show`: from a finished line to the screen

`ClarityLiveCoach/CoachModel+Lines.swift` lines 705–823

```swift
  705      /// Shows a suggestion, but never swaps a fresh line out from under the rep.
  706      func offer(_ s: Suggestion, id: Int, kind: Kind, askedAt: Date) {
  707          guard id == seq, !s.skip, !s.say.isEmpty, !doNotCall else { // do not call: nothing replaces the goodbye
  708              // MOVE: silent: keep the line if it still fits; clear it if the talk moved past it.
  709              let movedOn: Bool = {
  710                  guard let last = turns.last, last.speaker == .prospect else { return lineSuperseded }
  711                  let repAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
  712                  return lineSuperseded || repAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?")
  713              }()
  714              if s.move == "silent", id == seq, !doNotCall, status == .live, !suggestion.say.isEmpty,
  715                 SilentRule.clearNow(superseded: movedOn, delivered: lineDelivered, answered: answeredAfterDelivery, signals: signals()) {
  716                  CallTrace.event("suggestion.cleared", ["line": suggestion.say, "why": "Claude chose silent and the line was outdated"], sug: shownID)
  717                  suggestion = Suggestion()
  718                  lineSuperseded = false
  719              }
  720              if s.sayComplete || s.skip {
  721                  let why = doNotCall ? "do not call" : id != seq ? "stale: request #\(seq) is newer" : s.move == "silent" ? "Claude chose silent: no new line needed" : s.skip ? "Claude said skip" : "empty"
  722                  CallTrace.event("suggestion.dropped", ["line": s.say, "why": why], sug: id)
  723              }
  724              return
  725          }
  726          // Easier to read live: show the line once it's whole, not word by word (setting).
  727          let wholeLine = Prefs.wholeLine
  728          if wholeLine && !s.sayComplete { return }
  729          if specBasis != nil {
  730              if s.sayComplete, specHeld?.id != id {
  731                  CallTrace.event("suggestion.held_early", ["line": s.say, "basis": specBasis ?? "", "why": "drafted early: waits for them to stop"], sug: id)
  732              }
  733              specHeld = (s, id) // started early: wait until they really stop talking
  734              return
  735          }
  736          if kind == .reply, timedID != id {
  737              timedID = id // time from "they stopped talking" to the first words of the answer
  738              latency = max(0, Date().timeIntervalSince(confirmedAt ?? askedAt))
  739          }
  740          if id == shownID {
  741              // Once a line is whole on screen, its words are frozen: a late chunk never changes it (N2).
  742              if suggestion.sayComplete { return }
  743              if frozenShownID == id { return }
  744              if status == .live, signals().repSpeaking || !(interim[.rep] ?? "").isEmpty { frozenShownID = id; return } // reading it: freeze for good
  745              if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
  746              var s = s
  747              s.say = fillTags(s.say, for: calling) // never show a bare [Name] or [SDR]
  748              suggestion = s // same answer, still streaming in
  749              note(s)
  750              return
  751          }
  752          // The call is live and someone already talked: keep the opener the rep is reading.
  753          if kind == .opener, status == .live, repWordsInCall > 0 || turns.contains(where: { $0.speaker == .prospect })
  754              || signals().repSpeaking || !(interim[.rep] ?? "").isEmpty {
  755              if s.sayComplete { CallTrace.event("suggestion.dropped", ["line": s.say, "why": "opener arrived after the talk started"], sug: id) }
  756              return
  757          }
  758          // The AI thinks ahead, the screen follows the conversation: never swap the line while the rep is
  759          // speaking. Queue it, flag the old one as outdated, and show it the moment they stop.
  760          // A new prospect turn since the line appeared = the conversation moved on.
  761          // Only a real reply moves the conversation on (3+ words or a question), not "uh-huh" or "yeah".
  762          // Any answer to a question you asked counts too, even "yes" or "nope", so you never have to press Next.
  763          let youAsked = turns.dropLast().last { $0.speaker == .rep }?.text.trimmed.hasSuffix("?") ?? false
  764          if kind == .reply, repLedIDs.contains(id), !lineSuperseded || supersededLogged != shownID {
  765              supersededLogged = shownID
  766              CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id,
  767                                                        "why": "the rep moved on in their own words", "delivered": lineDelivered], sug: shownID)
  768              lineSuperseded = true
  769          }
  770          if kind == .reply, let last = turns.last, last.speaker == .prospect,
  771             youAsked || last.text.split(separator: " ").count >= 3 || last.text.contains("?") {
  772              if !lineSuperseded || supersededLogged != shownID {
  773                  supersededLogged = shownID
  774                  let why = youAsked ? "they answered your question" : last.text.contains("?") ? "they asked a question" : "they said something new (3+ words)"
  775                  CallTrace.event("suggestion.superseded", ["line": suggestion.say, "by_request": id, "prospect_said": last.text,
  776                                                            "why": why, "delivered": lineDelivered], sug: shownID)
  777                  ActivityLog.add("Coach #\(shownID): line outdated (\(why))")
  778              }
  779              lineSuperseded = true
  780          }
  781          // The rep moved past it while it was being written (asked, pivoted, or kept talking): drop it (round 2 #1).
  782          let readingOnScript = !lineDelivered && Delivery.onLine(line: suggestion.say, spoken: recentRepChunks.joined(separator: " "))
  783          let staleWhy = kind == .reply && id != shownID
  784              ? QueuedLine.staleReason(ageSeconds: 0, repWordsSinceQueued: readingOnScript ? 0 : repWordsInCall - repWordsAtLastAsk,
  785                                       repAskedSinceQueued: QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
  786                                                                                            lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate),
  787                                       repTextSinceQueued: repTextSinceAsk)
  788              : nil
  789          if freshLineIDs.contains(id) { // the rep pressed space: show it now, whatever is on screen
  790              defer { freshLineIDs.remove(id) } // still marked while show() counts it
  791              CallTrace.event("suggestion.fresh", ["line": s.say, "why": "the rep asked for a fresh line"], sug: id)
  792              show(s, id: id, kind: kind)
  793              return
  794          }
  795          let decision = CoachController.offer(isOpenerOrVoicemail: kind == .opener || kind == .voicemail, firstLine: shownID == 0,
  796                                               holdLine: holdLine, signals: signals(), staleReason: staleWhy)
  797          if case .drop(let why) = decision {
  798              CallTrace.event("suggestion.discarded", ["line": s.say, "why": "stale on arrival: \(why)", "rule": QueuedLine.ruleKind(why)], sug: id)
  799              // Only when they talked on in their own words: after a question or a pivot, the prospect's answer comes next.
  800              if why.hasPrefix("the rep said") { followRep(why: "the line arrived after the rep moved on") }
  801              return
  802          }
  803          if decision == .show {
  804              show(s, id: id, kind: kind)
  805          } else {
  806              if pending?.id != id {
  807                  let why = holdLine ? "held by you" : repSpeaking ? "you're speaking" : "you may be reading"
  808                  ActivityLog.add("Coach #\(id): line queued (\(why))")
  809                  CallTrace.event("suggestion.queued", ["line": s.say, "why": why, "signals": signals().trace], sug: id)
  810              }
  811              if let old = pending, old.id != id {
  812                  CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer queued line replaced it"], sug: old.id)
  813              }
  814              if pending?.id != id {
  815                  pendingQueuedAt = Date()
  816                  repWordsAtQueue = repWordsAtLastAsk // what the rep had said when this line was asked for
  817                  // C4: a question the rep asked while this line was still being written counts too.
  818                  repAskedSinceQueue = QueuedLine.repAskedSinceRequest(requestedAt: askedAt.timeIntervalSinceReferenceDate,
  819                                                                       lastRepQuestionAt: lastRepQuestionAt.timeIntervalSinceReferenceDate)
  820              }
  821              pending = (id, s)
  822          }
  823      }
```

`ClarityLiveCoach/CoachModel+Lines.swift` lines 869–898

```swift
  869      /// Called twice a second: a queued line shows once the rep stops speaking.
  870      func promotePendingIfReady() {
  871          guard status == .live, let p = pending, CoachMachine.isFresh(requestID: p.id, latestID: seq) else { return }
  872          let decision = CoachController.promote(holdLine: holdLine, signals: signals(),
  873                                                 ageSeconds: Date().timeIntervalSince(pendingQueuedAt),
  874                                                 repWordsSinceQueued: repWordsInCall - repWordsAtQueue,
  875                                                 repAskedSinceQueued: repAskedSinceQueue, repTextSinceQueued: repTextSinceAsk)
  876          guard decision != .wait else {
  877              if blockedLoggedID != p.id { // once per queued line, not every tick
  878                  blockedLoggedID = p.id
  879                  CallTrace.event("promotion.blocked", ["why": holdLine ? "held by the rep" : "not safe to replace yet",
  880                                                        "signals": signals().trace], sug: p.id)
  881              }
  882              return
  883          }
  884          // The rep's words are the source of truth: if they moved on while this waited, it's stale.
  885          if case .drop(let why) = decision {
  886              pending = nil
  887              ActivityLog.add("Coach #\(p.id): queued line dropped (\(why); \(QueuedLine.ruleKind(why)) rule)")
  888              CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)",
  889                                                       "rule": QueuedLine.ruleKind(why)], sug: p.id)
  890              // They asked their own question: the next move is the prospect's answer. Otherwise write the
  891              // next line from where the rep actually is.
  892              if !repAskedSinceQueue { followRep() }
  893              return
  894          }
  895          ActivityLog.add("Coach #\(p.id): queued line shown")
  896          CallTrace.event("suggestion.promoted", ["why": "safe to replace now (rep stopped, line read or delivered)"], sug: p.id)
  897          show(p.suggestion, id: p.id, kind: .reply)
  898      }
```

`ClarityLiveCoach/CoachModel+Lines.swift` lines 1024–1099

```swift
 1024      func show(_ s: Suggestion, id: Int, kind: Kind) {
 1025          // After an opt-out, only the goodbye line may ever show (round 2 #3).
 1026          if doNotCall, s.say != LiveCoach.optOutLine {
 1027              CallTrace.event("suggestion.dropped", ["line": s.say, "why": "do not call", "kind": "\(kind)"], sug: id)
 1028              return
 1029          }
 1030          if status == .live, !s.say.isEmpty {
 1031              let ms = lastHeardThemAt.map { Int(Date().timeIntervalSince($0) * 1000) }
 1032              ActivityLog.add("Coach line shown (\(kind)\(ms.map { ", \($0) ms after their last words" } ?? "")): \(s.say)")
 1033          }
 1034          var s = s
 1035          // THINK that doesn't hold up against this conversation never reaches the card: SAY shows instead, on purpose
 1036          // (the card says "SAY THIS"), and the reason is in the trace.
 1037          if status == .live, kind == .reply, Think.enabled, s.rowTag == nil, !s.nudge, !s.think.isEmpty {
 1038              let why = Think.problems(think: s.think, say: s.say, move: s.move, intent: ConversationIntent.classify(CoachPrompt.latestProspect),
 1039                                       objectionKind: ObjectionTracker.detect(CoachPrompt.latestProspect),
 1040                                       latestProspect: CoachPrompt.latestProspect, recentText: CoachPrompt.recentText,
 1041                                       scriptText: CoachPrompt.scriptText, answeredQuestions: CoachPrompt.answeredQuestions)
 1042              if !why.isEmpty {
 1043                  CallTrace.event("think.fallback", ["think": s.think, "say": s.say, "problems": why], sug: id)
 1044                  s.think = ""
 1045              }
 1046          } else if status == .live, kind == .reply, Think.enabled, s.rowTag == nil, !s.nudge, s.think.isEmpty {
 1047              CallTrace.event("think.fallback", ["think": "", "say": s.say, "problems": ["THINK was missing"]], sug: id)
 1048          }
 1049          s.say = fillTags(s.say, for: calling) // [SDR], {first name} and other slots Claude copied from the script
 1050          // Still an unfilled slot ([Day], [Firm] we don't know): never show it. Keep the current line (script rule).
 1051          if status == .live, kind == .reply, TokenFill.hasOpenSlot(s.say) {
 1052              CallTrace.event("suggestion.dropped", ["line": s.say, "why": "a [slot] couldn't be filled"], sug: id)
 1053              ActivityLog.add("Coach: a line had a blank to fill (\(s.say)); kept the current line")
 1054              showToast("No line with a blank in it. Say it your way, or press space for a fresh one.")
 1055              return
 1056          }
 1057          if kind == .opener, id != instantOpenerID, s.sayComplete { personalOpenerFor = calling }
 1058          if let old = pending, old.id != id {
 1059              ActivityLog.add("Coach #\(old.id): queued line discarded (newer one shown)")
 1060              CallTrace.event("suggestion.discarded", ["line": old.suggestion.say, "why": "a newer line was shown"], sug: old.id)
 1061          }
 1062          if status == .live, kind == .reply || kind == .opener, !s.say.isEmpty {
 1063              CoachPrompt.shownLines.append(s.say)
 1064              // Model test: only lines the call's model wrote (not the instant opener, script answers or a space-bar
 1065              // Sonnet line), and a line replaced before it could be read doesn't count as ignored.
 1066              if testLineCounted, !lineDelivered, Date().timeIntervalSince(shownAt) < 2 { callLinesShown -= 1 }
 1067              testLineCounted = kind == .reply && !s.nudge && s.say != LiveCoach.optOutLine && !freshLineIDs.contains(id)
 1068                  && !s.cue.hasPrefix("From your script") && !s.cue.hasPrefix("Two no")
 1069              if testLineCounted { callLinesShown += 1 }
 1070          }
 1071          if status == .live {
 1072              CallTrace.event("suggestion.shown", ["line": s.say, "think": s.think, "think_mode": Think.enabled, "cue": s.cue, "stage": s.stage, "move": s.move, "label": LineLook.label(move: s.move, exact: s.rowTag != nil), "key_part": LineLook.emphasis(s.say)?.key ?? "", "kind": "\(kind)",
 1073                                                   "replaced": suggestion.say, "replaced_delivered": lineDelivered], sug: id)
 1074          }
 1075          pending = nil
 1076          lineSuperseded = false
 1077          if kind == .reply { repTextSinceAsk = ""; repWordsAtLastAsk = repWordsInCall } // round 2 #9
 1078          priorLineOfferedTime = !suggestion.offered.isEmpty || GoalEvidence.mentionsTime(suggestion.say)
 1079          // The old line: partly said in the rep's own words? Then it isn't "never said" (H1).
 1080          if status == .live, !suggestion.say.isEmpty, !lineDelivered,
 1081             Delivery.likelyCovered(line: suggestion.say, spoken: repSaidSinceShown),
 1082             !CoachPrompt.likelyCoveredLines.contains(suggestion.say) {
 1083              CoachPrompt.likelyCoveredLines.append(suggestion.say)
 1084              CallTrace.event("delivery.likely", ["line": suggestion.say, "said": repSaidSinceShown,
 1085                                                  "confidence": Delivery.confidence(line: suggestion.say, spoken: repSaidSinceShown)], sug: shownID)
 1086          }
 1087          repSaidSinceShown = ""
 1088          lineDelivered = false
 1089          answeredAfterDelivery = false
 1090          shownID = id
 1091          shownAt = Date()
 1092          repWordsSinceShown = 0
 1093          suggestion = s
 1094          historyIndex = nil
 1095          if !s.say.isEmpty, s.sayComplete || kind != .reply { history.append((s: s, kind: kind)) }
 1096          self.kind = kind
 1097          problem = nil
 1098          note(s)
 1099      }
```

`ClarityLiveCoach/CoachModel+Lines.swift` lines 1101–1126

```swift
 1101      /// Bookkeeping for what a line tells us: stage reached, times offered, goal, voicemail.
 1102      func note(_ s: Suggestion) {
 1103          if status != .ready, !s.stage.isEmpty {
 1104              stagesSeen.insert(s.stage)
 1105              trackJourney(s.stage)
 1106          }
 1107          if voicemailActive, !s.textMessage.isEmpty || !s.linkedin.isEmpty || !s.linkedinMessage.isEmpty { fillFollowUp(from: s) }
 1108          // Remember which meeting times this line offered, so the next ones are different.
 1109          if !s.offered.isEmpty {
 1110              let dates = s.offered.compactMap { code in codeByDate.first { $0.value == code }?.key }
 1111              offeredTimes.formUnion(dates)
 1112              nextOffer = pickNextPair(from: availability.offerSlots())
 1113          }
 1114          if s.stage == "Closing" { availability.refreshIfOlder() } // fresh times while booking
 1115          // A closing line on screen is only a pending goal; the prospect's words confirm it (N4).
 1116          if s.stage == "Goal reached", !goalHit {
 1117              goalPending = true
 1118              goalPendingTurns = 2
 1119              // They often agree first ("Tuesday works") and the closing line follows: check their last words too.
 1120              if let last = turns.last(where: { $0.speaker == .prospect }) { confirmGoalIfAgreed(last.text, checkingEarlierTurn: true) }
 1121          }
 1122          // The model's stage is a hint only: it never decides voicemail or pickups (rules do),
 1123          // so swapping Haiku and Sonnet can't change the numbers.
 1124          if !s.stage.isEmpty { attempt?.modelStage(s.stage) }
 1125          if s.stage == "Voicemail", !sawVoicemail { CallTrace.event("voicemail.model_hint", ["why": "the model said Voicemail; rules decide"]) }
 1126      }
```

### 4.9 Writing lines ahead: the yes branch and following the rep

`ClarityLiveCoach/CoachModel+Lines.swift` lines 932–985

```swift
  932      /// The rep just asked a yes/no question: write the line for "yes" now, while they wait for the
  933      /// answer. It's held, never shown, until the prospect actually says yes. Open questions ("What do
  934      /// you use?") get nothing ahead: the answer comes from their real words.
  935      func prepareYesBranch(_ text: String) {
  936          // Keep the ready line through small talk; drop it for a new question or once the talk moved on (H3).
  937          if yesBranch != nil {
  938              yesBranchRepWords += text.split(separator: " ").count
  939              if YesBranchRule.keep(afterRepSaid: text, wordsSinceQuestion: yesBranchRepWords) { return }
  940              CallTrace.event("yes_branch.discarded", ["question": yesBranch?.question ?? "", "why": "the rep moved on or asked a new question"])
  941          }
  942          yesBranchTask?.cancel()
  943          yesBranch = nil
  944          yesBranchWanted = nil
  945          guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
  946                let q = RepQuestion.closedQuestion(in: text), let key = Keychain.read(.anthropic) else { return }
  947          yesBranchRepWords = 0
  948          yesBranchAskedAt = Date()
  949          let user = CoachPrompt.reply(turns: turns, latest: q, calling: calling, details: recordDetails, style: callOpener,
  950                                       openTimes: bookingText(), assumeYes: true)
  951          let system = self.system
  952          yesBranch = (q, Suggestion(say: "", cue: "", stage: ""), false)
  953          CallTrace.event("yes_branch.request", ["question": q, "user_message": user])
  954          let started = Date()
  955          yesBranchTask = Task { [weak self] in
  956              var text = ""
  957              try? await LiveCoach.client(key).stream(system: system, user: user, onText: { text = $0 }, onUsage: { u in
  958                  Task { @MainActor in CallTrace.event("claude.usage", u.merging(["yes_branch": 1]) { a, _ in a }) }
  959              })
  960              guard let self, !Task.isCancelled, self.yesBranch?.question == q else { return }
  961              CallTrace.event("claude.done", ["yes_branch": true, "ms": Int(Date().timeIntervalSince(started) * 1000), "output": text])
  962              var s = Suggestion.parse(text)
  963              s.sayComplete = true
  964              let problems = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
  965              if !problems.isEmpty, let fixed = LineRepair.fix(s.say) { s.say = fixed }
  966              let left = s.skip || s.say.isEmpty ? ["empty"] : Self.lineProblems(s)
  967              CallTrace.event("yes_branch.ready", ["question": q, "line": s.say, "ms": Int(Date().timeIntervalSince(started) * 1000),
  968                                                   "passed": left.isEmpty, "problems": left])
  969              if left.isEmpty { self.yesBranch = (q, s, true) } else { self.yesBranch = nil }
  970              // They already said yes while this was being written: show it now, or fall back to a normal answer.
  971              if let said = self.yesBranchWanted {
  972                  self.yesBranchWanted = nil
  973                  self.yesBranch = nil
  974                  if left.isEmpty, self.status == .live, !self.doNotCall {
  975                      CallTrace.event("yes_branch.used", ["question": q, "answer": said, "line": s.say, "late": true])
  976                      self.markRequestStart()
  977                      self.seq += 1
  978                      self.offer(s, id: self.seq, kind: .reply, askedAt: Date())
  979                  } else {
  980                      self.ask(.reply, user: CoachPrompt.reply(turns: self.turns, latest: said, calling: self.calling,
  981                                                               details: self.recordDetails, style: self.callOpener, openTimes: self.bookingText()))
  982                  }
  983              }
  984          }
  985      }
```

`ClarityLiveCoach/CoachModel+Lines.swift` lines 912–930

```swift
  912      /// After each thing the rep says: if they're off script, get the next line ready now, while they
  913      /// talk, so it's waiting when they pause. A queued line they've moved past is dropped first.
  914      func prepareWhileRepTalks(_ text: String) {
  915          guard status == .live, !doNotCall, !voicemailActive, !screenerActive, !suggestion.say.isEmpty else { return }
  916          let since = repWordsInCall - repWordsAtLastAsk
  917          guard !followPausedUntilQuiet,
  918                FollowRepLimit.allowed(repWordsSinceLastAsk: since, followsThisStretch: followsThisStretch) else { return }
  919          guard FollowRep.shouldPrepare(repJustSaid: text, recentRepSpeech: recentRepChunks.joined(separator: " "),
  920                                        shownLine: suggestion.say, shownLineDelivered: lineDelivered,
  921                                        repWordsSinceLastAsk: since) else { return }
  922          if let p = pending {
  923              pending = nil
  924              let why = "the rep said \(since) words of their own since"
  925              ActivityLog.add("Coach #\(p.id): queued line dropped while you talk (\(why); heuristic rule)")
  926              followPausedUntilQuiet = true // they're on their own roll: no more drafts until they pause
  927              CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "stale: \(why)", "rule": "heuristic"], sug: p.id)
  928          }
  929          followRep(why: "preparing ahead: the rep is off script (\(since) words since the last request)")
  930      }
```

`ClarityLiveCoach/CoachModel+Lines.swift` lines 900–910

```swift
  900      /// The rep went off script and paused without asking anything: the next line builds on what they
  901      /// actually said, not on what the script expected.
  902      func followRep(why: String = "the rep moved on from the queued line") {
  903          guard status == .live, !doNotCall, !voicemailActive, !screenerActive,
  904                let rep = turns.last, rep.speaker == .rep else { return }
  905          CallTrace.event("follow_rep", ["rep_said": rep.text, "why": why])
  906          followsThisStretch += 1
  907          nextIsRepLed = true
  908          ask(.reply, user: CoachPrompt.reply(turns: turns, latest: rep.text, calling: calling, details: recordDetails,
  909                                              style: callOpener, openTimes: bookingText(), repLed: true))
  910      }
```

### 4.10 Opt-out, handled in code

`ClarityLiveCoach/CoachModel+Lines.swift` lines 425–484

```swift
  425      /// "Take me off your list": the goodbye line, DoNotCall written in Salesforce, off every list, hang up. No AI.
  426      func handleOptOut(_ said: String) {
  427          guard !doNotCall else { return }
  428          yesShowTask?.cancel()
  429          let optOutCallID = CallTrace.callID
  430          doNotCall = true // terminal: every later draft, early start and queued line is blocked
  431          specTimer?.cancel()
  432          coachTask?.cancel()
  433          yesBranchTask?.cancel(); yesBranch = nil
  434          stillWithMeTask?.cancel()
  435          phoneTreeTask?.cancel()
  436          openerTask?.cancel()
  437          if let p = pending {
  438              CallTrace.event("suggestion.discarded", ["line": p.suggestion.say, "why": "do not call"], sug: p.id)
  439          }
  440          pending = nil
  441          specHeld = nil
  442          specBasis = nil
  443          uncoached = ""
  444          thinking = false
  445          CallTrace.event("state", ["from": coachState.rawValue, "to": CoachState.doNotCall.rawValue,
  446                                    "why": "opt-out phrase", "said": said, "cancelled_request": seq])
  447          coachState = .doNotCall
  448          seq += 1
  449          show(Suggestion(say: LiveCoach.optOutLine, cue: "Opt out. Say goodbye, then hang up. Saving Do Not Call in Salesforce...", stage: "Exit", sayComplete: true), id: seq, kind: .reply)
  450          guard let key = currentAttemptKey else { return }
  451          RemovedList.add(key)
  452          followUp = nil // no text, no LinkedIn
  453          CallTrace.event("crm.suppress", ["record": key, "actions": ["DoNotCall", "status", "off every list", "no text"]])
  454          outcomeSaved.insert(String(key.prefix(15))) // nothing more to log
  455          ActivityLog.add("Opt out from \(calling ?? key): \"\(said)\". Off every list, no text, writing DoNotCall and status")
  456          CallTrace.event("intent", ["intent": "opt_out", "said": said, "why": "opt-out phrase in their words", "action": "goodbye line and DoNotCall; the rep hangs up"])
  457          Task { [weak self] in
  458              do {
  459                  try await Salesforce.setDoNotCall(key)
  460                  ActivityLog.add("Opt out: DoNotCall saved in Salesforce for \(self?.calling ?? key)")
  461                  CallTrace.event("crm.saved", ["record": key, "field": "DoNotCall"])
  462                  // Only now say it's saved in Salesforce (the line itself stays as is).
  463                  if let self, self.suggestion.say == LiveCoach.optOutLine { self.suggestion.cue = "Opt out. Do Not Call saved in Salesforce. Hang up when you're done." }
  464              } catch {
  465                  ActivityLog.problem("Opt out: couldn't save DoNotCall in Salesforce: \(error.localizedDescription)")
  466                  CallTrace.event("crm.failed", ["record": key, "field": "DoNotCall", "error": error.localizedDescription])
  467                  if let self, CallTrace.callID == optOutCallID { // never on the next call's screen
  468                      if self.suggestion.say == LiveCoach.optOutLine {
  469                          self.suggestion.cue = "Off your list here, but Salesforce didn't save Do Not Call. Mark it by hand."
  470                      }
  471                      self.problem = "Do Not Call didn't save in Salesforce for \(self.calling ?? key). Mark it by hand."
  472                  }
  473              }
  474              // Status too: Leads go Unqualified, Contacts go Negative. Both keep them off every list.
  475              let status = key.hasPrefix("00Q") ? "Unqualified" : "Negative"
  476              do {
  477                  try await Salesforce.setStatus(of: key, to: status, note: "Asked not to be called again: \"\(said.prefix(200))\"")
  478                  ActivityLog.add("Opt out: status set to \(status)")
  479              } catch {
  480                  ActivityLog.problem("Opt out: couldn't set status to \(status): \(error.localizedDescription)")
  481              }
  482              // No automatic hang-up: the rep says goodbye and hangs up themselves.
  483          }
  484      }
```

`CoachCore/CoachCore.swift` lines 193–227

```swift
  193  /// "Take me off your list", "don't call me back": matched in code, no AI.
  194  public enum OptOut {
  195      public static let phrases = ["take me off your list", "take me off the list", "remove me from your list",
  196                                   "remove me from the list", "don't call me again", "do not call me again",
  197                                   "stop calling me", "put me on your do not call", "do not call list",
  198                                   "don't ever call", "never call me", "quit calling", "lose my number",
  199                                   "don't call me back", "do not call me back", "don't call back", "don't call here",
  200                                   "don't call this number", "never call here", "never call this number", "remove my number",
  201                                   "take my number off", "delete my number", "don't contact me", "do not contact me",
  202                                   "stop contacting me", "never call again", "don't call again", "do not call again"]
  203  
  204      /// "Don't call me back" can mean "call me later" ("...until Tuesday"). Those only count on a final
  205      /// transcript, and not when a later time follows. Clear phrases ("take me off your list") count at once.
  206      static let ambiguous = ["don't call me back", "do not call me back", "don't call back", "don't call me again",
  207                              "do not call me again", "don't call again", "do not call again", "don't call here"]
  208  
  209      /// The words contain a phrase that might be a callback ("...until Tuesday"): wait for the full pause before acting.
  210      public static func hasAmbiguous(_ text: String) -> Bool {
  211          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
  212          return ambiguous.contains { t.contains($0) }
  213      }
  214      static let deferrals = ["until", "till", "later", "tomorrow", "next", "after", "monday", "tuesday", "wednesday",
  215                              "thursday", "friday", "in a few", "in an hour", "when", "this afternoon", "tonight"]
  216  
  217      public static func matches(_ text: String, isFinal: Bool = true) -> Bool {
  218          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "dont ", with: "don't ")
  219          for p in phrases where t.contains(p) {
  220              guard ambiguous.contains(p) else { return true }
  221              guard isFinal, let r = t.range(of: p) else { continue }
  222              let after = " " + t[r.upperBound...].prefix(40).split(whereSeparator: { !$0.isLetter && $0 != "'" }).joined(separator: " ") + " "
  223              if !deferrals.contains(where: { after.contains(" \($0) ") }) { return true } // whole words: "still" isn't "till"
  224          }
  225          return false
  226      }
  227  }
```

### 4.11 Fresh line on request (space bar) and the call summary

`ClarityLiveCoach/CoachModel+Lines.swift` lines 106–120

```swift
  106      /// The rep asked for a different line right now. Skips the wait and the hold.
  107      func newLine(extra: String = "The rep asked for a different line than the last one.") {
  108          // ⌘J and the space bar are one feature: the fresh line from the whole call.
  109          if status == .live, !voicemailActive { freshLine(); return }
  110          CallTrace.event("manual", ["action": "Different line", "was": suggestion.say])
  111          guard status == .live, !voicemailActive else { return }
  112          let latest = uncoached.trimmed.isEmpty ? (turns.last { $0.speaker == .prospect }?.text ?? "") : uncoached.trimmed
  113          uncoached = ""
  114          shownAt = .distantPast // no hold for a line the rep asked for
  115          repWordsSinceShown = 99
  116          ask(.reply, user: CoachPrompt.reply(
  117              turns: turns, latest: latest, calling: calling, details: recordDetails, style: callOpener,
  118              openTimes: bookingText()
  119          ) + "\n" + extra)
  120      }
```

`ClarityLiveCoach/CoachModel+Lines.swift` lines 394–423

```swift
  394      /// Every 4 prospect turns, Haiku writes a short summary of the call in the background, so each live
  395      /// line only needs the last minute word for word.
  396      func updateSummaryIfDue() {
  397          let total = turns.count
  398          guard CallMemoryRules.summaryDue(totalTurns: total, summaryCovers: CoachPrompt.summaryCoversTurns, inFlight: summaryInFlight),
  399                let key = Keychain.read(.anthropic) else { return }
  400          let theirs = turns.filter { $0.speaker == .prospect }.count
  401          let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
  402          let callID = CallTrace.callID // the summary belongs to this call only
  403          summaryInFlight = true
  404          Task {
  405              defer { if CallTrace.callID == callID { self.summaryInFlight = false } }
  406              var c = LiveCoach.client(key)
  407              c.maxTokens = 250
  408              var text = ""
  409              try? await c.stream(system: "Summarize a live sales call for a coach in 3 to 6 short bullets: who they are, their situation, any numbers, pains, objections raised, what was agreed. Only what was said. No preamble.",
  410                                  user: transcript) { text = $0 }
  411              guard CallMemoryRules.acceptSummary(currentCallID: CallTrace.callID, summaryCallID: callID,
  412                                                  summaryCovers: total, storedCovers: CoachPrompt.summaryCoversTurns) else {
  413                  CallTrace.event("memory.rejected", ["why": "older than the stored summary, or from another call", "covers_turns": total])
  414                  return
  415              }
  416              if !text.isEmpty {
  417                  CoachPrompt.liveSummary = text
  418                  CoachPrompt.summaryCoversTurns = total
  419                  CallTrace.memVersion += 1
  420                  CallTrace.event("memory.update", ["summary": text, "covers_turns": total, "prospect_turns": theirs, "evidence_chars": transcript.count])
  421              }
  422          }
  423      }
```

## 5. Rule-based shortcuts that bypass Claude

Every place a line (or the absence of one) is produced without a live Claude call for that turn.

| # | Shortcut | Where | What it shows | Guarded by |
|---|---|---|---|---|
| 1 | **Opt-out phrases** ("take me off your list"...) | `handleOptOut`, `OptOut.matches`; `prospectFinished` and `scheduleEarlyStart` | fixed goodbye line `LiveCoach.optOutLine`, sets `doNotCall` (terminal for the call), writes Do Not Call and a status to Salesforce. The app does not hang up; the rep says goodbye and hangs up | Deterministic. Ambiguous phrases ("don't call me back") wait up to 2.5 s for a later time (`PendingOptOut`) |
| 2 | **Two no's / a no plus a sign-off** | `prospectFinished` (`Rejection.isNo`, `Rejection.callOver`) | fixed "Totally understand. Thanks for your time. Have a good one." and `callClosed = true` (nothing more is coached) | Deterministic phrase lists in `Rejection` |
| 3 | **Script answers ("instant answer")** | `instantAnswer` -> `ScriptAnswers.matchInContext` | the matched script row's `Say` word for word, `cue = "From your script: <row>"` | Section 6. Since Nov 20: blocked on direct questions, no's, sign-offs, and phrases that are only a small part of a long sentence |
| 4 | **Yes branch** | `prepareYesBranch`, `prospectFinished` | a line written *ahead* by Claude while the rep waited, shown on a clear yes (`ProspectReply.kind == .yes`) | Written earlier by Claude, so it is not "no Claude" but it bypasses the live request for that turn. Discarded if older than `YesBranchRule.maxAge` or the rep moved on |
| 5 | **Early draft reuse** | `scheduleEarlyStart`, `prospectFinished` (`early.used`) | the line Claude wrote while they were still talking, if the final words are identical | `specBasis == normalized(said)` |
| 6 | **Plain greeting** | `prospectFinished` (`coach.skipped`) | nothing: the opener already answers "Hello?" | `onlyGreeting` |
| 7 | **Filler** | `isMeaningful` | nothing | |
| 8 | **Screener** | `showScreenerLine`, `Screener.detects` | fixed "This is [name] calling for [name]." | Deterministic |
| 9 | **Phone tree** | `askPhoneTree` | route and keys (a separate Claude prompt, `CoachPrompt.phoneTree`) | |
| 10 | **Voicemail** | `showVoicemail` in `CoachModel+FollowUp.swift` (line 99) | the pre-written voicemail from the script/Claude | |
| 11 | **Opener** | `instantOpener`, `scriptOpenerLine` | the script's opener word for word, Claude personalizes a moment later | |
| 12 | **Still with me?** | `scheduleStillWithMe` | nudge after 6 s of silence | |
| 13 | **Line check, code-only repairs** | `fixLine` -> `LineRepair.fix` | the same line with an abbreviation/em-dash/second question fixed | no extra Claude request |


## 6. ScriptAnswers: prewritten script responses

`ScriptAnswers` reads every table row of the script that has a **Sounds like** column and a **Say** column, and builds a list of `(id, phrases, say)`. A phrase is any comma/semicolon/slash separated fragment of two or more words. Matching is a plain `String.contains` on the lowercased transcript, longest phrase wins. It does not look at meaning.

The matched row's `Say` is shown with no AI call (`instantAnswer`). Three things changed after the Nov 20 call: `matchInContext` adds intent and length guards (below), and the mid-sentence path no longer fires.

The script is not hand-written for this table: the generated backbone script contains these tables (`ScriptSkeleton.swift`), and `Coach.swift` line 435 rebuilds `ScriptAnswers` whenever the script text changes.


`CoachCore/CoachCore.swift` lines 412–497

```swift
  412  /// Approved answers from the script (objections, questions, blockers), matched in code: no AI wait.
  413  public struct ScriptAnswers: Sendable {
  414      public struct Entry: Sendable, Equatable { public let id: String; public let phrases: [String]; public let say: String }
  415      public let entries: [Entry]
  416  
  417      public init(entries: [Entry]) { self.entries = entries }
  418  
  419      /// Reads every table row with a "Sounds like" and a "Say" column (" | " or tab separated).
  420      public init(script: String) {
  421          var out: [Entry] = []
  422          var soundsCol: Int?, sayCol: Int?
  423          for raw in script.components(separatedBy: "\n") {
  424              let line = raw.trimmingCharacters(in: .whitespaces)
  425              let sep = line.contains("|") ? "|" : (line.contains("\t") ? "\t" : nil)
  426              guard let sep else { continue }
  427              let cols = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
  428              if let s = cols.firstIndex(where: { $0.lowercased() == "sounds like" }), let y = cols.firstIndex(where: { $0.lowercased() == "say" }) {
  429                  soundsCol = s; sayCol = y; continue
  430              }
  431              guard let s = soundsCol, let y = sayCol, cols.count > max(s, y) else { continue }
  432              let say = cols[y].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  433              guard !say.isEmpty, !say.lowercased().hasPrefix("show"), !say.contains("(") else { continue }
  434              let phrases = cols[s].lowercased()
  435                  .components(separatedBy: CharacterSet(charactersIn: ",;/\"“”"))
  436                  .map { $0.trimmingCharacters(in: .whitespaces) }
  437                  .filter { $0.split(separator: " ").count >= 2 } // two words or more: safe to match
  438              guard !phrases.isEmpty else { continue }
  439              out.append(Entry(id: cols[0], phrases: phrases, say: say))
  440          }
  441          entries = out
  442      }
  443  
  444      /// The approved answer whose "sounds like" phrase appears in what they said (longest match wins).
  445      public func match(_ said: String) -> Entry? { bestMatch(said)?.entry }
  446  
  447      func bestMatch(_ said: String) -> (entry: Entry, phrase: String)? {
  448          let t = said.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  449          var best: (Entry, String)?
  450          for e in entries {
  451              for p in e.phrases where t.contains(p) {
  452                  if best == nil || p.count > best!.1.count { best = (e, p) }
  453              }
  454          }
  455          return best.map { ($0.0, $0.1) }
  456      }
  457  
  458      /// The instant answer only when it fits what they meant, not just shared words (Nov 20: "What is this
  459      /// about?" got a discovery row; "I'm not the right fit" got "Pain nothing"). nil + why when it's blocked.
  460      public func matchInContext(_ said: String, answeredQuestions: [String] = []) -> (entry: Entry?, why: String) {
  461          guard let (entry, phrase) = bestMatch(said) else { return (nil, "no Sounds-like phrase in their words") }
  462          switch ConversationIntent.classify(said) {
  463          case .optOut, .ending: return (nil, "they're ending the call: higher-priority rule")
  464          case .question: return (nil, "they asked a direct question: answer it first, not a script row")
  465          case .rejection:
  466              // A clear no gets no sales question: only a row that just acknowledges (or offers one email) may answer it.
  467              let kind = ObjectionTracker.detect(said)
  468              guard kind != nil, ObjectionTracker.detect(phrase) == kind else {
  469                  return (nil, "they declined; the matched row (\(entry.id)) isn't about that")
  470              }
  471              let low = entry.say.lowercased()
  472              if entry.say.contains("?"), !low.contains("email") {
  473                  return (nil, "they clearly declined; row \(entry.id) asks another sales question")
  474              }
  475          case .objection:
  476              // An objection may get the row written for that same objection.
  477              let kind = ObjectionTracker.detect(said)
  478              guard kind != nil, ObjectionTracker.detect(phrase) == kind else {
  479                  return (nil, "they raised an objection; the matched row (\(entry.id)) isn't about it")
  480              }
  481          case .other: break
  482          }
  483          // High confidence only: the phrase must be most of what they said. A short phrase inside a longer
  484          // sentence is a word overlap, not their meaning ("I don't know" in "I don't know that I'm the right fit").
  485          let saidWords = Delivery.words(said).count
  486          let phraseWords = Delivery.words(phrase).count
  487          if saidWords > 14 { return (nil, "too long to be a one-line answer to a script row") }
  488          if saidWords > 3, Double(phraseWords) / Double(saidWords) < 0.5 {
  489              return (nil, "\"\(phrase)\" is only a small part of what they said")
  490          }
  491          // The row's own line asks something already answered on this call: don't ask it again.
  492          if let repeated = answeredQuestions.first(where: { Repeats.same($0, entry.say) }) {
  493              return (nil, "row \(entry.id) repeats a question already answered: \"\(repeated)\"")
  494          }
  495          return (entry, "\"\(phrase)\" matches what they meant")
  496      }
  497  }
```

### 6.1 The intent classifier and the role check added on Nov 20

`CoachCore/CoachCore.swift` lines 1217–1242

```swift
 1217  /// What the prospect's turn is doing, decided in code before any line is picked. Higher-priority
 1218  /// situations (opt-out, ending, a direct question, a no) outrank the script's stage.
 1219  public enum ConversationIntent: String, Sendable {
 1220      /// rejection = a clear refusal ("not interested", "no thanks", "not a fit"): no more sales questions.
 1221      /// objection = a concern or reflex brush-off ("we use Gong", "no time", "send me info", "we're good"):
 1222      /// one relevant follow-up is fine.
 1223      case optOut, ending, question, rejection, objection, other
 1224  
 1225      static let questionStarts: Set<String> = ["what", "who", "why", "how", "where", "when", "which", "is", "are", "do",
 1226                                               "does", "can", "could", "would", "will", "did"]
 1227      static let greetings: Set<String> = ["hello", "hi", "hey", "yes", "yeah", "speaking", "this", "is", "it"]
 1228  
 1229      public static func classify(_ said: String) -> ConversationIntent {
 1230          let t = said.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1231          let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
 1232          if OptOut.matches(said) { return .optOut }
 1233          if ObjectionTracker.detect(said) == "ending the call" || Rejection.isSignOff(said) { return .ending }
 1234          if Rejection.isNo(said) { return .rejection }
 1235          // "Hello?" is a greeting, not a question.
 1236          if words.count <= 3, words.allSatisfy(greetings.contains) { return .other }
 1237          if t.contains("?") || AnswerEvidence.kind(said) == .deflection { return .question }
 1238          if let first = words.first, questionStarts.contains(first), words.count >= 3 { return .question }
 1239          if ObjectionTracker.detect(said) != nil { return .objection }
 1240          return .other
 1241      }
 1242  }
```

`CoachCore/CoachCore.swift` lines 1244–1257

```swift
 1244  /// The rep is the caller. A line must never have the rep claim the prospect's role (Nov 20:
 1245  /// "Yes, I'm the one who decides on those tools.").
 1246  public enum RoleCheck {
 1247      static let claims = ["i'm the one who decides", "i am the one who decides", "i'm the one that decides",
 1248                           "i'm the decision maker", "i am the decision maker", "i'm the decision-maker",
 1249                           "i make the decisions", "i make those decisions", "i decide on", "i'm the one who handles",
 1250                           "i'm in charge of", "i am in charge of", "i'm the right person", "i am the right person",
 1251                           "i'm the one in charge", "i own that", "i handle those", "i handle that"]
 1252  
 1253      public static func speaksAsProspect(_ line: String) -> Bool {
 1254          let t = line.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1255          return claims.contains { t.contains($0) }
 1256      }
 1257  }
```

### 6.2 The call site

`ClarityLiveCoach/CoachModel+Lines.swift` lines 840–867

```swift
  840      /// The approved script answer for what they said, shown with no AI wait. True if one matched.
  841      func instantAnswer(_ said: String) -> Bool {
  842          guard status == .live, !doNotCall else { return false }
  843          let answers = scriptAnswers
  844          // Only when they're answering the rep's question: otherwise a phrase match is out of context.
  845          let repJustAsked = turns.dropLast().last { $0.speaker == .rep }?.text.contains("?") ?? false
  846          // Never ahead of higher-priority rules: a direct question, a no or a sign-off goes to the full coach.
  847          let (hit, why) = answers.matchInContext(said, answeredQuestions: CoachPrompt.answeredQuestions)
  848          guard repJustAsked, let e = hit else {
  849              CallTrace.event("script.match", ["searched": answers.entries.count, "matched": false, "said": said,
  850                                               "intent": ConversationIntent.classify(said).rawValue,
  851                                               "why": repJustAsked ? why : "the rep hadn't just asked a question"])
  852              return false
  853          }
  854          CallTrace.event("script.match", ["searched": answers.entries.count, "matched": true, "row": e.id,
  855                                           "phrases": e.phrases, "said": said, "answer": e.say, "why": why])
  856          if suggestion.say == e.say || pending?.suggestion.say == e.say { return true } // already up
  857          coachTask?.cancel() // any slower AI draft for this is stale now
  858          thinking = false
  859          specBasis = nil
  860          specHeld = nil
  861          markRequestStart()
  862          seq += 1
  863          ActivityLog.add("Coach #\(seq): instant answer from your script (\(e.id)), no AI")
  864          offer(Suggestion(say: e.say, cue: "From your script: \(e.id)", stage: "Objection", sayComplete: true),
  865                id: seq, kind: .reply, askedAt: Date())
  866          return true
  867      }
```

`ClarityLiveCoach/Coach.swift` lines 437–443

```swift
  437      var scriptAnswers: ScriptAnswers {
  438          let text = campaign.pastedScript
  439          if let c = scriptAnswersCache, c.text == text { return c.answers }
  440          let a = ScriptAnswers(script: text)
  441          scriptAnswersCache = (text, a)
  442          return a
  443      }
```

## 7. QuestionTracker and ObjectionTracker

Both are plain structs in `CoachCore.swift`. They are fed every **final** turn (not interim words) from `CoachModel+Audio.swift`, and each exposes `promptText`, which is copied into `CoachPrompt.questionFacts` / `objectionFacts` and then into the next user message. Claude is told "trust these". Neither one changes what is shown directly; they only change what Claude is told (and, for objections, `Rejection` separately counts no's).

* **QuestionTracker**: records questions asked by the rep or the prospect, with a status: open, answered, interrupted, abandoned, uncertain. A reply that is a counter-question, a deflection ("what's this about") or "I don't know" is classified by `AnswerEvidence.kind` and marks the question *uncertain*, not answered.
* **ObjectionTracker**: detects an objection from phrase lists (`kinds`), then follows it: raised -> addressed (the rep's words matched `addressCues` or an acknowledgement) -> resolved / still open / uncertain based on the prospect's next words (`resolvedWords`, `stillOpenWords`, `uncertainWords`, `contrastWords`). `promptText` also hard-codes three instructions: "won't share" = don't ask again, "ending the call" = close politely, anything else = the status.


`CoachCore/CoachCore.swift` lines 499–607

```swift
  499  /// Questions asked on the call and what happened to each, tracked in code from the transcript
  500  /// (not inferred by the model). Fed to Haiku as facts: what's still open, what's already answered.
  501  public struct QuestionTracker: Sendable {
  502      public enum Speaker: String, Sendable { case rep, prospect }
  503      public enum Status: String, Sendable { case open, answered, interrupted, abandoned, uncertain }
  504      public struct Question: Sendable, Equatable {
  505          public let id: Int
  506          public let asker: Speaker
  507          public let text: String
  508          public var status: Status
  509          public var answer: String
  510      }
  511      public enum Change: Sendable, Equatable {
  512          case asked(Question), answered(Question), interrupted(Question), abandoned(Question), uncertain(Question)
  513      }
  514  
  515      public private(set) var questions: [Question] = []
  516      private var nextID = 1
  517      public init() {}
  518  
  519      private static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
  520      private static let starts = ["who", "what", "when", "where", "why", "how", "do", "does", "did", "is", "are", "can",
  521                                   "could", "would", "will", "should", "have", "has", "any", "which"]
  522  
  523      /// The questions in a turn: sentences ending in "?" (or starting like a question when no punctuation came through).
  524      public static func questions(in text: String) -> [String] {
  525          var out: [String] = []
  526          var current = ""
  527          for ch in text {
  528              current.append(ch)
  529              if ".?!".contains(ch) {
  530                  let s = current.trimmingCharacters(in: .whitespaces)
  531                  if ch == "?" { out.append(s) }
  532                  current = ""
  533              }
  534          }
  535          if out.isEmpty, !text.contains("."), let first = text.lowercased().split(separator: " ").first,
  536             starts.contains(String(first)), text.split(separator: " ").count >= 4 {
  537              out.append(text.trimmingCharacters(in: .whitespaces))
  538          }
  539          return out
  540      }
  541  
  542      /// One finished turn. `overlapped`: the other person was still talking when this turn started.
  543      public mutating func add(turn text: String, from speaker: Speaker, overlapped: Bool = false) -> [Change] {
  544          var changes: [Change] = []
  545          let words = text.lowercased().split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
  546          let substantive = words.contains { !Self.filler.contains($0) && !$0.isEmpty }
  547          // The other side's open questions: answered only by a real answer. A question back, a
  548          // deflection or a refusal leaves it uncertain (still not answered). Cut off if talked over.
  549          for i in questions.indices where questions[i].asker != speaker
  550              && (questions[i].status == .open || questions[i].status == .uncertain) && substantive {
  551              if overlapped, questions[i].status == .open {
  552                  questions[i].status = .interrupted
  553                  changes.append(.interrupted(questions[i]))
  554              } else if AnswerEvidence.isAnswer(text) {
  555                  questions[i].status = .answered
  556                  questions[i].answer = text
  557                  changes.append(.answered(questions[i]))
  558              } else if questions[i].status == .open {
  559                  questions[i].status = .uncertain
  560                  questions[i].answer = text
  561                  changes.append(.uncertain(questions[i]))
  562              }
  563          }
  564          let asked = Self.questions(in: text)
  565          // Asking again before getting an answer abandons the earlier one.
  566          if !asked.isEmpty {
  567              for i in questions.indices where questions[i].asker == speaker
  568                  && (questions[i].status == .open || questions[i].status == .interrupted || questions[i].status == .uncertain) {
  569                  questions[i].status = .abandoned
  570                  changes.append(.abandoned(questions[i]))
  571              }
  572          }
  573          for q in asked {
  574              let new = Question(id: nextID, asker: speaker, text: q, status: .open, answer: "")
  575              nextID += 1
  576              questions.append(new)
  577              changes.append(.asked(new))
  578          }
  579          return changes
  580      }
  581  
  582      /// A reply that shares meaning with the question, or says enough to be a real answer.
  583      static func isConfirmed(_ q: Question) -> Bool {
  584          let n = Delivery.words(q.answer).count
  585          if n >= 8 { return true }
  586          let shared = Repeats.meaning(q.text).intersection(Repeats.meaning(q.answer)).count
  587          return n >= 3 && shared >= 1
  588      }
  589  
  590      /// For the model: facts about questions tracked by rules from the transcript.
  591      public var promptText: String {
  592          let repAnswered = questions.filter { $0.asker == .rep && $0.status == .answered }
  593          let theirsOpen = questions.filter { $0.asker == .prospect && $0.status == .open }
  594          let repOpen = questions.filter { $0.asker == .rep && ($0.status == .open || $0.status == .interrupted) }
  595          let repUncertain = questions.filter { $0.asker == .rep && $0.status == .uncertain }
  596          var lines: [String] = []
  597          if !theirsOpen.isEmpty { lines.append("Prospect questions NOT yet answered (answer these first): " + theirsOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
  598          if !repOpen.isEmpty { lines.append("Rep questions still waiting for an answer: " + repOpen.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
  599          if !repUncertain.isEmpty { lines.append("Rep questions NOT answered (they asked back, deflected or declined; don't treat as answered, don't push): " + repUncertain.map { "\"\($0.text)\" -> they said \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
  600          // Answered is judged by simple rules (the next reply looked like an answer), so it comes in two strengths.
  601          let confirmed = repAnswered.filter { Self.isConfirmed($0) }
  602          let probable = repAnswered.filter { !Self.isConfirmed($0) }
  603          if !confirmed.isEmpty { lines.append("Asked AND answered, their words show it (never ask again): " + confirmed.map { "\"\($0.text)\" -> \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
  604          if !probable.isEmpty { lines.append("Probably answered (a short or indirect reply; never ask again, but don't treat their answer as settled): " + probable.map { "\"\($0.text)\" -> \"\($0.answer.prefix(80))\"" }.joined(separator: "; ")) }
  605          return lines.joined(separator: "\n")
  606      }
  607  }
```

`CoachCore/CoachCore.swift` lines 609–752

```swift
  609  /// Objections on this call, tracked in code from the transcript (no AI).
  610  /// Addressed is not resolved: "addressed" only means the rep answered it. Only the prospect's
  611  /// next words can mark it resolved, still open, or uncertain.
  612  public struct ObjectionTracker: Sendable {
  613      public enum Status: String, Sendable { case raised, addressed, resolved, stillOpen = "still_open", uncertain }
  614      public struct Objection: Sendable, Equatable {
  615          public let id: Int
  616          public let kind: String          // e.g. "not interested"
  617          public let raisedText: String    // their exact words
  618          public let raisedTurn: Int       // transcript turn number
  619          public var status: Status
  620          public var addressedText = ""    // the rep's answer
  621          public var addressedTurn = 0
  622          public var evidenceText = ""     // the prospect's words that decided resolved / still open / uncertain
  623          public var evidenceTurn = 0
  624      }
  625      public struct Change: Sendable, Equatable {
  626          public let objection: Objection
  627          public let from: Status?
  628          public let why: String
  629      }
  630  
  631      /// Common cold-call objections: a name and the phrases that mean it.
  632      public static let kinds: [(String, [String])] = [
  633          ("won't share", ["can't discuss", "cannot discuss", "not something i can discuss", "can't share", "cannot share",
  634                           "not something i can share", "confidential", "can't talk about", "not able to discuss", "not at liberty"]),
  635          ("ending the call", ["thank you for calling", "thanks for calling", "thanks for the call", "have a good day",
  636                               "have a great day", "i have to go", "i've got to go", "gotta go", "i need to go"]),
  637          ("not interested", ["not interested", "no interest", "not for us", "we're good", "we are good", "i'm good", "pass on",
  638                              "don't know that i'm interested", "don't think i'm interested", "not the right fit",
  639                              "right fit for this", "not a good fit", "not a fit"]),
  640          ("no time", ["no time", "too busy", "i'm busy", "in a meeting", "bad time", "not a good time", "driving"]),
  641          ("send info", ["send me an email", "send me something", "send me info", "email me", "send it over", "send me some"]),
  642          ("already have it", ["we already have", "we already use", "we use another", "we use a ", "already working with", "we have a partner", "we have someone", "in house", "in-house"]),
  643          ("happy as is", ["happy with", "it's working", "works fine", "we're fine", "don't need", "do not need", "no need"]),
  644          ("price", ["too expensive", "no budget", "can't afford", "cost too much", "costs too much", "not in the budget"]),
  645          ("wrong person", ["not the right person", "not my area", "not my department", "talk to someone else", "i don't handle"]),
  646          ("call later", ["call me later", "call back later", "call me next", "reach out next", "maybe later", "not right now"]),
  647          ("trust", ["how did you get my number", "who gave you", "is this a sales call", "is this a scam"]),
  648      ]
  649      static let stillOpenWords = ["no", "nope", "still not", "not interested", "i said", "like i said", "already told you", "not really", "i don't think so",
  650                                   "can't do", "cannot do", "won't work", "not looking", "not a priority", "no thanks"]
  651      static let contrastWords = ["but", "however", "though", "although"]
  652      /// Words that show the rep spoke to this kind of objection (plus general acknowledgments).
  653      static let addressCues: [String: [String]] = [
  654          "not interested": ["interested", "fair", "understand", "get it", "makes sense", "hear you"],
  655          "no time": ["quick", "time", "seconds", "minute", "busy", "later", "call back"],
  656          "send info": ["email", "send", "info"],
  657          "already have it": ["already", "use", "using", "partner", "tool", "today", "working", "current"],
  658          "happy as is": ["fine", "working", "need", "happy", "good", "today"],
  659          "price": ["cost", "price", "budget", "free", "expensive", "money", "invest", "spend"],
  660          "wrong person": ["right person", "who", "handles", "point me", "best person", "in charge"],
  661          "call later": ["later", "when", "better time", "call back", "tomorrow", "next week"],
  662          "trust": ["number", "list", "linkedin", "found", "sales call", "honest", "research"],
  663          "won't share": ["no problem", "understand", "fair", "of course", "totally"],
  664          "ending the call": [],
  665      ]
  666      static let acknowledgments = ["fair", "understand", "totally get", "get it", "makes sense", "hear you", "appreciate", "no problem", "of course"]
  667  
  668      /// Did the rep's words speak to this objection? Not just any 3 words: words tied to it, or an acknowledgment.
  669      static func addresses(kind: String, text: String) -> Bool {
  670          has(text, (addressCues[kind] ?? []) + acknowledgments)
  671      }
  672      static let resolvedWords = ["sure", "okay", "ok", "go ahead", "yeah", "yes", "tell me", "what is it", "how does", "how much", "what do you",
  673                                  "that's fair", "fair enough", "makes sense", "i guess so", "interesting", "send it", "let's do", "that works"]
  674      static let uncertainWords = ["hmm", "maybe", "i don't know", "not sure", "we'll see", "possibly", "i guess"]
  675  
  676      public private(set) var objections: [Objection] = []
  677      private var nextID = 1
  678      public init() {}
  679  
  680      /// The objection kind in these words, or nil. Script "sounds like" phrases can add their own kinds.
  681      public static func detect(_ text: String, extra: [(String, [String])] = []) -> String? {
  682          let t = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
  683          return (extra + kinds).first { $0.1.contains { t.contains($0) } }?.0
  684      }
  685  
  686      static func has(_ text: String, _ words: [String]) -> Bool {
  687          let t = " " + text.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted).joined(separator: " ") + " "
  688          return words.contains { t.contains(" \($0) ") }
  689      }
  690  
  691      /// Feed each finalized turn. `turn` is the transcript turn number (for evidence in the trace).
  692      public mutating func add(turn text: String, from speaker: QuestionTracker.Speaker, turn: Int,
  693                               extra: [(String, [String])] = []) -> [Change] {
  694          var out: [Change] = []
  695          func set(_ i: Int, _ s: Status, why: String) {
  696              let from = objections[i].status
  697              objections[i].status = s
  698              out.append(Change(objection: objections[i], from: from, why: why))
  699          }
  700          if speaker == .rep {
  701              // The rep answered any objection still waiting. Addressed, not resolved.
  702              for i in objections.indices where [.raised, .stillOpen].contains(objections[i].status)
  703                  && Self.addresses(kind: objections[i].kind, text: text) {
  704                  objections[i].addressedText = text
  705                  objections[i].addressedTurn = turn
  706                  set(i, .addressed, why: "rep answered it (turn \(turn)); waiting on the prospect")
  707              }
  708              return out
  709          }
  710          // Prospect: first judge any objection the rep just addressed, from their words only.
  711          let newKind = Self.detect(text, extra: extra)
  712          for i in objections.indices where objections[i].status == .addressed {
  713              objections[i].evidenceText = text
  714              objections[i].evidenceTurn = turn
  715              if newKind == objections[i].kind || Self.has(text, Self.stillOpenWords) {
  716                  set(i, .stillOpen, why: "prospect pushed back again (turn \(turn))")
  717              } else if Self.has(text, Self.uncertainWords) {
  718                  set(i, .uncertain, why: "prospect's answer is unsure (turn \(turn))")
  719              } else if Self.has(text, Self.resolvedWords) && !Self.has(text, Self.contrastWords) {
  720                  set(i, .resolved, why: "prospect agreed (turn \(turn))")
  721              } else if Self.has(text, Self.contrastWords) {
  722                  set(i, .uncertain, why: "prospect agreed but added a 'but' (turn \(turn))")
  723              } else {
  724                  set(i, .uncertain, why: "prospect's answer doesn't settle it (turn \(turn))")
  725              }
  726          }
  727          // A new objection (not one already open of the same kind).
  728          if let kind = newKind, !objections.contains(where: { $0.kind == kind && $0.status != .resolved }) {
  729              objections.append(Objection(id: nextID, kind: kind, raisedText: text, raisedTurn: turn, status: .raised))
  730              nextID += 1
  731              out.append(Change(objection: objections[objections.count - 1], from: nil, why: "prospect raised it (turn \(turn))"))
  732          }
  733          return out
  734      }
  735  
  736      /// For Claude's context. Empty when there are none.
  737      public var promptText: String {
  738          objections.map { o in
  739              var line = "- \(o.kind) (turn \(o.raisedTurn), \"\(o.raisedText)\"): "
  740              switch o.status {
  741              case .raised where o.kind == "won't share": line += "they won't share this. Respect it: don't ask about it again"
  742              case .raised where o.kind == "ending the call": line += "they're ending the call. Thank them and close politely, no more questions"
  743              case .raised: line += "NOT answered yet"
  744              case .addressed: line += "rep answered it, prospect hasn't responded yet. NOT resolved"
  745              case .resolved: line += "resolved: they said \"\(o.evidenceText)\""
  746              case .stillOpen: line += "STILL OPEN after the rep's answer: they said \"\(o.evidenceText)\""
  747              case .uncertain: line += "unclear: they said \"\(o.evidenceText)\""
  748              }
  749              return line
  750          }.joined(separator: "\n")
  751      }
  752  }
```

### 7.1 The small rules the trackers and the coach lean on

`CoachCore/CoachCore.swift` lines 984–1006

```swift
  984  /// Is the prospect's reply an answer? A question back, a deflection or a refusal is not.
  985  public enum AnswerEvidence {
  986      public enum Kind: String, Sendable { case answer, counterQuestion, deflection, unsure, filler }
  987      static let filler: Set<String> = ["uh", "um", "hmm", "mm", "mhm", "uh-huh", "huh"]
  988      static let deflections = ["why are you asking", "why do you ask", "what do you mean", "who is this", "who's this",
  989          "can't discuss", "cannot discuss", "not something i can", "rather not", "none of your", "not going to share",
  990          "can't share", "cannot share", "why do you want to know", "what's this about", "what is this about", "can't say"]
  991      static let unsure = ["not sure", "i don't know", "no idea", "hard to say", "it depends", "depends"]
  992      static let whStarts: Set<String> = ["why", "what", "who", "how", "huh", "meaning", "sorry"]
  993  
  994      public static func kind(_ text: String) -> Kind {
  995          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  996          let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
  997          if words.isEmpty || words.allSatisfy(filler.contains) { return .filler }
  998          if deflections.contains(where: { t.contains($0) }) { return .deflection }
  999          if unsure.contains(where: { t.contains($0) }) { return .unsure }
 1000          if t.contains("?") { return .counterQuestion }
 1001          if words.count <= 3, let first = words.first, whStarts.contains(first) { return .counterQuestion }
 1002          return .answer
 1003      }
 1004  
 1005      public static func isAnswer(_ text: String) -> Bool { kind(text) == .answer }
 1006  }
```

`CoachCore/CoachCore.swift` lines 921–941

```swift
  921  /// What kind of answer the prospect gave to the rep's yes/no question. Only a clear yes uses the
  922  /// line written ahead; no, unsure, or anything else gets a fresh answer from their real words.
  923  public enum ProspectReply {
  924      public enum Kind: String, Sendable { case yes, no, unsure, other }
  925      static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "correct", "right", "absolutely",
  926          "definitely", "totally", "go", "ahead", "fire", "away", "shoot", "of", "course", "please", "alright", "fine", "i", "guess", "it", "does", "is", "true"]
  927  
  928      public static func kind(_ text: String) -> Kind {
  929          let t = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
  930          let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
  931          guard !words.isEmpty else { return .other }
  932          if ["not sure", "maybe", "depends", "hmm", "i don't know", "kind of", "sort of", "we'll see"].contains(where: { t.contains($0) }) { return .unsure }
  933          if words.contains("no") || words.contains("nope") || words.contains("nah") || t.contains("not really")
  934              || t.contains("not interested") || t.contains("i'm good") || t.contains("don't") || t.contains("not now") { return .no }
  935          if words.count <= 5, words.allSatisfy(yesWords.contains),
  936             words.contains(where: { ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "correct", "right", "absolutely", "definitely", "go", "shoot", "alright", "fine", "true"].contains($0) }) {
  937              return .yes
  938          }
  939          return .other
  940      }
  941  }
```

`CoachCore/CoachCore.swift` lines 1146–1175

```swift
 1146  /// "Two no's and a go": one no gets one respectful question; two no's (or a no plus a sign-off) ends it (call 6).
 1147  public enum Rejection {
 1148      // Only clear no's. Reflex brush-offs ("we're good", "I'm good") don't count: they often open up right after.
 1149      static let nos = ["not interested", "not relevant", "no thanks", "no thank you", "not a fit",
 1150                        "not for us", "not really interested", "doesn't apply", "not something we need",
 1151                        "not the right fit", "not a good fit", "right fit for this"]
 1152      static let signOffs = ["yep thanks", "yep, thanks", "bye", "take care", "have a good one", "have a good day", "have a great day",
 1153                             "gotta go", "got to go", "thanks anyway", "thank you anyway"]
 1154  
 1155      public static func isNo(_ text: String) -> Bool {
 1156          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
 1157          // "...though our CRM data is a mess": a no that opens a door isn't a no.
 1158          if [" but ", " though", " however", " although"].contains(where: { t.contains($0) }) { return false }
 1159          if nos.contains(where: { t.contains($0) }) { return true }
 1160          // "I don't think this is really relevant", "this isn't relevant to us"
 1161          // "I don't know that I'm interested", "I don't know that I'm the right fit" (Nov 20): soft no's.
 1162          let negated = ["don't think", "don't know that", "don't know if", "not", "isn't", "doesn't"].contains { t.contains($0) }
 1163          return negated && (t.contains("relevant") || t.contains("interested") || t.contains("a fit") || t.contains("right fit"))
 1164      }
 1165  
 1166      public static func isSignOff(_ text: String) -> Bool {
 1167          let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: ".", with: "")
 1168          return signOffs.contains { t.contains($0) }
 1169      }
 1170  
 1171      /// Done: two no's, or a no that comes with a sign-off.
 1172      public static func callOver(nosSoFar: Int, latest: String) -> Bool {
 1173          nosSoFar >= 2 || (nosSoFar >= 1 && isSignOff(latest))
 1174      }
 1175  }
```

`CoachCore/CoachCore.swift` lines 1009–1026

```swift
 1009  /// Call memory rules (C3, M4).
 1010  public enum CallMemoryRules {
 1011      /// A background summary is kept only for the same call, and only if it covers more turns than the one stored.
 1012      public static func acceptSummary(currentCallID: String, summaryCallID: String, summaryCovers: Int, storedCovers: Int) -> Bool {
 1013          currentCallID == summaryCallID && summaryCovers > storedCovers
 1014      }
 1015  
 1016      /// First turn (index) sent word for word: everything the summary doesn't cover, and never fewer than the last `minRecent`.
 1017      public static func verbatimStart(totalTurns: Int, summaryCovers: Int, hasSummary: Bool, minRecent: Int = 10) -> Int {
 1018          guard hasSummary, totalTurns > 12 else { return 0 }
 1019          return max(0, min(summaryCovers, totalTurns - minRecent))
 1020      }
 1021  
 1022      /// Ask for a fresh summary when 6+ turns aren't covered (a late or failed one is retried).
 1023      public static func summaryDue(totalTurns: Int, summaryCovers: Int, inFlight: Bool) -> Bool {
 1024          !inFlight && totalTurns > 12 && totalTurns - summaryCovers >= 6
 1025      }
 1026  }
```

### 7.2 Where they are fed (`CoachModel+Audio.swift`)

`ClarityLiveCoach/CoachModel+Audio.swift` lines 330–352

```swift
  330          let kindNow = timeline.segments[speaker == .rep ? .rep : .prospect]?.last?.kind
  331          let overlapped = kindNow == .interruption || kindNow == .overlap
  332          for change in questionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, overlapped: overlapped) {
  333              switch change {
  334              case .asked(let q): CallTrace.event("question.asked", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
  335              case .answered(let q): CallTrace.event("question.answered", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "answer": q.answer])
  336              case .interrupted(let q): CallTrace.event("question.interrupted", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "cut_off_by": text])
  337              case .abandoned(let q): CallTrace.event("question.abandoned", ["id": q.id, "by": q.asker.rawValue, "text": q.text])
  338              case .uncertain(let q): CallTrace.event("question.uncertain", ["id": q.id, "by": q.asker.rawValue, "text": q.text, "reply": q.answer,
  339                                                                             "reply_kind": AnswerEvidence.kind(q.answer).rawValue])
  340              }
  341          }
  342          CoachPrompt.questionFacts = questionTracker.promptText // current before the next prompt is built
  343          CoachPrompt.answeredQuestions = questionTracker.questions.filter { $0.asker == .rep && $0.status == .answered }.map(\.text)
  344          for c in objectionTracker.add(turn: text, from: speaker == .rep ? .rep : .prospect, turn: CallTrace.turn) {
  345              let o = c.objection
  346              CallTrace.event("objection.\(o.status.rawValue)", [
  347                  "id": o.id, "kind": o.kind, "from": c.from?.rawValue ?? "none", "to": o.status.rawValue, "why": c.why,
  348                  "raised": ["turn": o.raisedTurn, "text": o.raisedText],
  349                  "addressed": ["turn": o.addressedTurn, "text": o.addressedText],
  350                  "evidence": ["turn": o.evidenceTurn, "text": o.evidenceText]])
  351              ActivityLog.add("Objection \(o.kind): \(c.from?.rawValue ?? "new") -> \(o.status.rawValue)")
  352          }
```

### 7.3 The running summary used on long calls

`ClarityLiveCoach/CoachModel+Lines.swift` lines 394–423

```swift
  394      /// Every 4 prospect turns, Haiku writes a short summary of the call in the background, so each live
  395      /// line only needs the last minute word for word.
  396      func updateSummaryIfDue() {
  397          let total = turns.count
  398          guard CallMemoryRules.summaryDue(totalTurns: total, summaryCovers: CoachPrompt.summaryCoversTurns, inFlight: summaryInFlight),
  399                let key = Keychain.read(.anthropic) else { return }
  400          let theirs = turns.filter { $0.speaker == .prospect }.count
  401          let transcript = turns.map { "\($0.speaker == .rep ? "Rep" : "Prospect"): \($0.text)" }.joined(separator: "\n")
  402          let callID = CallTrace.callID // the summary belongs to this call only
  403          summaryInFlight = true
  404          Task {
  405              defer { if CallTrace.callID == callID { self.summaryInFlight = false } }
  406              var c = LiveCoach.client(key)
  407              c.maxTokens = 250
  408              var text = ""
  409              try? await c.stream(system: "Summarize a live sales call for a coach in 3 to 6 short bullets: who they are, their situation, any numbers, pains, objections raised, what was agreed. Only what was said. No preamble.",
  410                                  user: transcript) { text = $0 }
  411              guard CallMemoryRules.acceptSummary(currentCallID: CallTrace.callID, summaryCallID: callID,
  412                                                  summaryCovers: total, storedCovers: CoachPrompt.summaryCoversTurns) else {
  413                  CallTrace.event("memory.rejected", ["why": "older than the stored summary, or from another call", "covers_turns": total])
  414                  return
  415              }
  416              if !text.isEmpty {
  417                  CoachPrompt.liveSummary = text
  418                  CoachPrompt.summaryCoversTurns = total
  419                  CallTrace.memVersion += 1
  420                  CallTrace.event("memory.update", ["summary": text, "covers_turns": total, "prospect_turns": theirs, "evidence_chars": transcript.count])
  421              }
  422          }
  423      }
```

## 8. CoachMachine and CoachController: request, queue, replace, suppress

This is the display controller. It decides nothing about *what* to say. It decides, from `CoachSignals` (who is speaking, whether the rep started or delivered the line, how long it has been on screen), whether a finished line may replace the one on screen, must wait, or is stale.

Key rules:
* A line is never replaced while the rep is speaking.
* An undelivered line is only replaced by something *new from the prospect*, and only after its reading time (`readingTime(words:)`, 2 to 6.5 s).
* A delivered line, or one the conversation moved past, can be replaced.
* While the prospect is talking, a queued line waits (`waitForProspect`) so the rep keeps eyes on them.
* A queued line is dropped as stale if the rep asked their own question, pivoted, said 8+ words of their own, or 8 seconds passed (`QueuedLine.staleReason`).
* `MOVE: silent` keeps the current line only if it still fits (`SilentRule`).
* `doNotCall` freezes the screen on the goodbye line.


`CoachCore/CoachCore.swift` lines 19–44

```swift
   19  /// Everything the state machine looks at, sampled twice a second.
   20  public struct CoachSignals: Sendable {
   21      public var hasLine: Bool
   22      public var prospectSpeaking: Bool
   23      public var repSpeaking: Bool
   24      public var secondsSinceShown: Double
   25      public var repStarted: Bool          // rep has said words since the line appeared
   26      public var delivered: Bool           // the line's meaning was said
   27      public var prospectAnsweredSince: Bool // prospect spoke after the rep delivered it
   28      public var queued: Bool              // a newer line is waiting
   29      public var queuedIsForNewTopic: Bool // the prospect moved on (interrupt/new question)
   30      public var lineWords: Int            // words in the line on screen (to protect silent reading)
   31      public var overlapping: Bool         // both sides talking at the same moment (a real interruption)
   32      public var repOnLine: Bool           // what the rep is saying matches the line on screen
   33      public var doNotCall: Bool           // they asked not to be called again
   34  
   35      public init(hasLine: Bool, prospectSpeaking: Bool, repSpeaking: Bool, secondsSinceShown: Double,
   36                  repStarted: Bool, delivered: Bool, prospectAnsweredSince: Bool, queued: Bool, queuedIsForNewTopic: Bool,
   37                  lineWords: Int = 0, overlapping: Bool = false, repOnLine: Bool = false, doNotCall: Bool = false) {
   38          self.hasLine = hasLine; self.prospectSpeaking = prospectSpeaking; self.repSpeaking = repSpeaking
   39          self.secondsSinceShown = secondsSinceShown; self.repStarted = repStarted; self.delivered = delivered
   40          self.prospectAnsweredSince = prospectAnsweredSince; self.queued = queued; self.queuedIsForNewTopic = queuedIsForNewTopic
   41          self.lineWords = lineWords
   42          self.overlapping = overlapping; self.repOnLine = repOnLine; self.doNotCall = doNotCall
   43      }
   44  }
```

`CoachCore/CoachCore.swift` lines 56–97

```swift
   56  public enum CoachMachine {
   57      /// How long a brand-new line is protected for reading before an un-started line can be swapped.
   58      public static let readingGrace = 1.2
   59  
   60      /// Silent reading can't be seen, so protect it by length: about 4 words a second, 1.2 to 5 seconds.
   61      /// Reading under pressure: about 3 words a second, plus about 1.5 s to start speaking. 2 to 6.5 s.
   62      public static func readingTime(words: Int) -> Double { min(6.5, max(2.0, Double(words) / 3 + 1.5)) }
   63  
   64      public static func state(_ s: CoachSignals) -> CoachState {
   65          if s.doNotCall { return .doNotCall }
   66          // Only real overlap is an interruption. One side answering right after the other is a normal turn.
   67          if s.overlapping { return .interrupted }
   68          // Delivering = saying the line on screen. Any other rep talk ("okay", small talk) is just talking.
   69          // Once delivered and answered, new rep talk is the rep's own words, not this line.
   70          if s.repSpeaking {
   71              let onThisLine = s.hasLine && !(s.delivered && s.prospectAnsweredSince) && (s.repOnLine || s.delivered)
   72              return onThisLine ? .delivering : .repTalking
   73          }
   74          if s.queued && s.queuedIsForNewTopic && s.repStarted && !s.delivered { return .superseded }
   75          if s.prospectSpeaking { return .listening }
   76          guard s.hasLine else { return .idle }
   77          if s.delivered && s.prospectAnsweredSince { return .resolved }
   78          if !s.repStarted { return .reading } // one steady label while it's theirs to read (no flicker)
   79          return .reading
   80      }
   81  
   82      /// May a newer line replace the one on screen right now?
   83      /// Never while the rep speaks. Not during the first moment of reading. Otherwise yes if the rep
   84      /// hasn't started it, it's been delivered, or the conversation clearly moved on.
   85      public static func canReplace(_ s: CoachSignals) -> Bool {
   86          if s.doNotCall { return false } // the goodbye line stays; nothing replaces it
   87          guard s.hasLine else { return true }
   88          if s.repSpeaking { return false }
   89          // Not started: only something new from the prospect replaces it, never the clock alone, and
   90          // never before the line has had its reading time (about 4 words a second, up to 5 s).
   91          if !s.repStarted { return s.queuedIsForNewTopic && s.secondsSinceShown >= readingTime(words: s.lineWords) }
   92          return s.delivered || s.queuedIsForNewTopic
   93      }
   94  
   95      /// Answers only count if they're for the newest request (older ones finishing late are dropped).
   96      public static func isFresh(requestID: Int, latestID: Int) -> Bool { requestID == latestID }
   97  }
```

`CoachCore/CoachCore.swift` lines 1075–1108

```swift
 1075  /// The screen controller's two decisions, shared by the app and the replay tests (H7), so the tests
 1076  /// prove the code the app actually runs.
 1077  public enum CoachController {
 1078      public enum Offer: Equatable, Sendable { case show, queue, drop(String) }
 1079      public enum Promote: Equatable, Sendable { case wait, show, drop(String) }
 1080  
 1081      /// A queued line waits while the prospect is talking, so the rep's eyes stay on them.
 1082      /// It shows when they stop. (A line arriving right as they finish, like the ready "yes" line, still shows.) Exceptions live elsewhere and are untouched: openers, voicemail,
 1083      /// screeners, opt-out (the goodbye line), and a line the rep asked for with Space.
 1084      public static func waitForProspect(_ s: CoachSignals) -> Bool {
 1085          s.hasLine && s.prospectSpeaking && !s.doNotCall
 1086      }
 1087  
 1088      /// A finished line arrives. Openers, voicemails and the first line show at once; anything else
 1089      /// only if the line on screen can be replaced now, else it waits in the queue.
 1090      /// `staleReason`: why the rep has moved past this line since it was asked for (checked before showing too).
 1091      public static func offer(isOpenerOrVoicemail: Bool, firstLine: Bool, holdLine: Bool, signals: CoachSignals,
 1092                               staleReason: String? = nil) -> Offer {
 1093          if isOpenerOrVoicemail || firstLine { return .show }
 1094          if let why = staleReason { return .drop(why) }
 1095          return !holdLine && CoachMachine.canReplace(signals) ? .show : .queue
 1096      }
 1097  
 1098      /// A queued line, checked on each tick or when the rep's speech ends: wait, show, or drop as stale.
 1099      public static func promote(holdLine: Bool, signals: CoachSignals, ageSeconds: Double, repWordsSinceQueued: Int,
 1100                                 repAskedSinceQueued: Bool, repTextSinceQueued: String) -> Promote {
 1101          guard !holdLine, !waitForProspect(signals), CoachMachine.canReplace(signals) else { return .wait }
 1102          if let why = QueuedLine.staleReason(ageSeconds: ageSeconds, repWordsSinceQueued: repWordsSinceQueued,
 1103                                              repAskedSinceQueued: repAskedSinceQueued, repTextSinceQueued: repTextSinceQueued) {
 1104              return .drop(why)
 1105          }
 1106          return .show
 1107      }
 1108  }
```

`CoachCore/CoachCore.swift` lines 755–790

```swift
  755  /// A line waiting in the queue (held while the rep talked) is only shown if it still fits.
  756  /// The rep's own words are the source of truth: if they've moved on, the old line is dropped.
  757  public enum QueuedLine {
  758      public static let maxAge = 8.0
  759      public static let maxRepWords = 8
  760  
  761      /// "heuristic" (the word or time limit, a safety net) or "conversation" (the rep asked their own
  762      /// question, a real change in the talk). Logged with every drop so the two can be told apart.
  763      public static func ruleKind(_ reason: String) -> String {
  764          reason.contains("asked") || reason.contains("pivot") ? "conversation" : "heuristic"
  765      }
  766  
  767      /// Phrases a rep uses to change direction, with or without a question mark.
  768      static let pivots = ["quick question", "before i let you go", "one last thing", "actually", "let me ask", "can i ask", "curious"]
  769  
  770      /// The rep changed direction in their own words: an unpunctuated question or a pivot phrase.
  771      public static func repPivoted(_ text: String) -> Bool {
  772          let t = text.lowercased()
  773          return pivots.contains(where: { t.contains($0) }) || !QuestionTracker.questions(in: text).isEmpty
  774      }
  775  
  776      /// C4: the rep asked a question after this line was requested (even while it was still being written).
  777      public static func repAskedSinceRequest(requestedAt: Double, lastRepQuestionAt: Double) -> Bool {
  778          lastRepQuestionAt > requestedAt
  779      }
  780  
  781      /// Why it's stale, or nil if it can still be shown.
  782      public static func staleReason(ageSeconds: Double, repWordsSinceQueued: Int, repAskedSinceQueued: Bool,
  783                                     repTextSinceQueued: String = "") -> String? {
  784          if repAskedSinceQueued { return "the rep asked their own question since" }
  785          if repPivoted(repTextSinceQueued) { return "the rep pivoted in their own words since" }
  786          if repWordsSinceQueued >= maxRepWords { return "the rep said \(repWordsSinceQueued) words of their own since" }
  787          if ageSeconds > maxAge { return String(format: "waited %.0f s; the talk moved on", ageSeconds) }
  788          return nil
  789      }
  790  }
```

`CoachCore/CoachCore.swift` lines 229–243

```swift
  229  /// MOVE: silent keeps the line on screen only if it still fits. If the talk moved past it, it's cleared.
  230  public enum SilentRule {
  231      public static func clearCurrent(superseded: Bool, delivered: Bool, answered: Bool) -> Bool {
  232          superseded || (delivered && answered)
  233      }
  234  
  235      /// The same, but never pulled from under the rep: not while they talk or are still reading it.
  236      public static func clearNow(superseded: Bool, delivered: Bool, answered: Bool, signals: CoachSignals) -> Bool {
  237          guard clearCurrent(superseded: superseded, delivered: delivered, answered: answered) else { return false }
  238          if signals.repStarted && !signals.delivered { return false } // partway through it: let them finish
  239          var s = signals
  240          s.queuedIsForNewTopic = superseded || s.queuedIsForNewTopic
  241          return CoachMachine.canReplace(s)
  242      }
  243  }
```

`CoachCore/CoachCore.swift` lines 245–274

```swift
  245  /// When to start Claude before the prospect is done. A one or two word fragment ("No.") is not
  246  /// worth a request: it almost always grows ("No. No. Just don't call me back."), wasting the draft.
  247  public enum EarlyStart {
  248      public static let minFinishedWords = 4 // real words, not "I", "yeah", "so"
  249      public static let minUnfinishedWords = 6
  250  
  251      /// Another early draft for the same turn only when their meaning moved: 5+ more words, or a sentence
  252      /// finished since the last draft. Stops a burst of near-identical requests while they talk.
  253      public static let maxDraftsPerTurn = 2
  254      public static func shouldRedraft(previous: String?, text: String, draftsThisTurn: Int) -> Bool {
  255          guard draftsThisTurn < maxDraftsPerTurn else { return false }
  256          guard let previous else { return true }
  257          let grew = text.split(separator: " ").count - previous.split(separator: " ").count
  258          let finishedNow = (text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
  259          let finishedBefore = (previous.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
  260          return grew >= 5 || (finishedNow && !finishedBefore && grew >= 2)
  261      }
  262  
  263      /// Milliseconds to wait for the words to hold still, or nil for "don't start early".
  264      public static func delayMS(for text: String) -> Int? {
  265          let t = text.trimmingCharacters(in: .whitespaces)
  266          if OptOut.matches(t) || OptOut.hasAmbiguous(t) { return nil } // handled in code, never drafted (Fix 3)
  267          let filler: Set<String> = ["i", "yeah", "so", "um", "uh", "well", "oh", "like", "okay", "ok", "and", "but", "the", "a"]
  268          let words = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).filter { !filler.contains(String($0)) }.count
  269          let finished = t.last.map { ".?!".contains($0) } ?? false
  270          if finished && words >= minFinishedWords { return 200 }
  271          if words >= minUnfinishedWords { return 450 }
  272          return nil
  273      }
  274  }
```

`CoachCore/CoachCore.swift` lines 846–861

```swift
  846  /// Prepare the next line while the rep is still talking off script, so it's ready the moment they
  847  /// pause (instead of dropping the old line at the pause and making them wait for a new one).
  848  public enum FollowRep {
  849      /// Should a new rep-led line be requested now, after the rep's latest words?
  850      /// - Not when they just asked a question (the prospect's answer comes next).
  851      /// - Not while they're reading the line on screen (they're on script).
  852      /// - Only once they've said 8+ of their own words since the last request.
  853      /// - `recentRepSpeech`: the rep's last couple of transcript chunks, so a line read across two
  854      ///   chunks still counts as on the line.
  855      public static func shouldPrepare(repJustSaid: String, recentRepSpeech: String, shownLine: String,
  856                                       shownLineDelivered: Bool, repWordsSinceLastAsk: Int) -> Bool {
  857          if repJustSaid.contains("?") { return false }
  858          if Delivery.onLine(line: shownLine, spoken: recentRepSpeech) && !shownLineDelivered { return false }
  859          return repWordsSinceLastAsk >= QueuedLine.maxRepWords
  860      }
  861  }
```

`CoachCore/CoachCore.swift` lines 1177–1184

```swift
 1177  /// When to write a line from the rep's own talk (call 6: 12 wasted calls on a monologue).
 1178  public enum FollowRepLimit {
 1179      public static let minWords = 15
 1180      /// At most one per stretch of rep talk (until the prospect speaks again), and only after 15+ of their words.
 1181      public static func allowed(repWordsSinceLastAsk: Int, followsThisStretch: Int) -> Bool {
 1182          followsThisStretch == 0 && repWordsSinceLastAsk >= minWords
 1183      }
 1184  }
```

`CoachCore/CoachCore.swift` lines 1029–1042

```swift
 1029  /// When to keep or drop the line written ahead for "yes" (H3).
 1030  public enum YesBranchRule {
 1031      /// Keep it through small talk after the question ("Just a quick one."); drop it for a new yes/no
 1032      /// question (a new one is written) or once the rep has said 8+ more words (the context moved on).
 1033      public static func keep(afterRepSaid text: String, wordsSinceQuestion: Int) -> Bool {
 1034          RepQuestion.closedQuestion(in: text) == nil && wordsSinceQuestion < QueuedLine.maxRepWords
 1035      }
 1036  
 1037      /// A ready yes line expires: older than this since the question, it's not used, even on a clear yes.
 1038      public static let maxAge = 12.0
 1039      /// If they say yes while it's still being written, wait at most this long, then answer fresh.
 1040      public static let maxWait = 1.2
 1041      public static func usable(ageSinceQuestion: Double) -> Bool { ageSinceQuestion <= maxAge }
 1042  }
```

`CoachCore/CoachCore.swift` lines 944–957

```swift
  944  /// The conversational move Claude picks before writing the line. "silent" means the rep doesn't need
  945  /// a new line right now (they're mid-thought, or the line on screen still fits).
  946  public enum Move: String, CaseIterable, Sendable {
  947      case answer, clarify, discover, acknowledge, objection, close, silent
  948  
  949      /// "MOVE: discover" -> .discover. nil if the line isn't a MOVE line.
  950      public static func parse(_ line: String) -> Move? {
  951          let t = line.trimmingCharacters(in: .whitespaces)
  952          guard t.uppercased().hasPrefix("MOVE:") else { return nil }
  953          let word = t.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
  954              .split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
  955          return Move(rawValue: word) ?? (word == "handle" ? .objection : nil)
  956      }
  957  }
```

### 8.1 Where the signals come from

`ClarityLiveCoach/Coach.swift` lines 452–467

```swift
  452      func signals() -> CoachSignals {
  453          let raw = timeline.now(Date().timeIntervalSinceReferenceDate)
  454          // Rep done? The transcriber's end-of-speech call and a sentence that isn't left hanging come
  455          // first; the time windows are only the fallback.
  456          let repTalking = RepTurn.stillTalking(wordsInTheAir: Date().timeIntervalSince(lastRepSpeechAt) < 0.35 && !repEndpointed,
  457                                                endpointed: repEndpointed, lastFinal: lastRepFinal,
  458                                                secondsSinceFinal: Date().timeIntervalSince(lastRepFinalAt), inFallbackWindow: raw.rep)
  459          let repInterim = !(interim[.rep] ?? "").trimmingCharacters(in: .whitespaces).isEmpty // words on the wire (H2)
  460          let talk = (rep: repTalking || raw.overlap || repInterim, prospect: raw.prospect && !(repTalking && RepTurn.hangs(lastRepFinal)), overlap: raw.overlap)
  461          return CoachSignals(hasLine: !suggestion.say.isEmpty, prospectSpeaking: talk.prospect, repSpeaking: talk.rep,
  462                       secondsSinceShown: Date().timeIntervalSince(shownAt), repStarted: !repSaidSinceShown.isEmpty || !(interim[.rep] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
  463                       delivered: lineDelivered, prospectAnsweredSince: answeredAfterDelivery,
  464                       queued: pending != nil, queuedIsForNewTopic: lineSuperseded,
  465                       lineWords: suggestion.say.split(separator: " ").count, overlapping: talk.overlap,
  466                       repOnLine: Delivery.onLine(line: suggestion.say, spoken: repSaidSinceShown), doNotCall: doNotCall)
  467      }
```

## 9. Script and stage tracking

**How the script reaches Claude.** The script is not parsed into a stage machine. The whole generated script text is placed in the system message (`Campaign.promptText`, section below), and Claude is told to "track the script's state from the call so far" and walk the pick order (instructions in `CoachPrompt.system`). The app never tells Claude which stage the call is in; Claude reports `STAGE:` and the app only records it.

**What the app does with the stage Claude reports** (`note(_:)` and `trackJourney`, `CoachModel+Lines.swift`): stores it in `stagesSeen`, moves the progress step (`journeyStep`), arms the booking and goal logic (`Closing`, `Goal reached`), and passes it to the call record as a hint (`attempt?.modelStage`). `CoachPrompt.lastSaidStage` is set from the stage of the last line the rep actually delivered and is the only stage fact sent back to Claude ("The last step the rep actually covered").

**What the app does not do:** it does not track "stage" in code from the transcript, does not check that the stage Claude names exists in the script, and does not use stage to select which part of the script to send. Every request sends the same full script.

**Where script text reaches the card besides Claude:** `ScriptAnswers` (section 6), the opener (`scriptOpenerLine`), voicemail/texts/LinkedIn (`ScriptTemplates`, read once by Claude from the whole script), and the **My Script** card (`ScriptOutlineCard.currentID`, a display-only highlight that guesses the stage from Claude's `STAGE:` text).


`ClarityLiveCoach/CoachModel+Lines.swift` lines 10–20

```swift
   10      func trackJourney(_ stage: String) {
   11          let step: Int?
   12          switch stage {
   13          case "Opener", "Screener", "Gatekeeper", "Voicemail": step = 0
   14          case "Discovery": step = 1
   15          case "Value": step = 2
   16          case "Closing", "Goal reached": step = 3
   17          default: step = nil // Objection, Exit: stay where we are
   18          }
   19          if let step { journeyStep = step } // follows the call both ways (calls aren't linear)
   20      }
```

`ClarityLiveCoach/Coach.swift` lines 114–117

```swift
  114      /// The four steps shown at the top: Opener -> Discovery -> Value -> Close.
  115      static let journey = ["Opener", "Discovery", "Value", "Close"]
  116      @Published var journeyStep = 0
  117      var nextStepName: String? { journeyStep + 1 < Self.journey.count ? Self.journey[journeyStep + 1] : nil }
```

`ClarityLiveCoach/Campaign.swift` lines 81–92

```swift
   81      /// What Claude reads. Only filled-in sections are included.
   82      var promptText: String {
   83          var parts = ["# Campaign: \(name)"]
   84          parts.append("Objective: \(objective.isEmpty ? "Not set. Infer it from the script." : objective)")
   85          for section in Self.sections where !self[keyPath: section.key].trimmed.isEmpty {
   86              parts.append("## \(section.title)\n\(self[keyPath: section.key].trimmed)")
   87          }
   88          if !pastedScript.trimmed.isEmpty {
   89              parts.append("## Call script (the script leads: use its lines in its words)\n\(pastedScript.trimmed)")
   90          }
   91          return parts.joined(separator: "\n\n")
   92      }
```

`ClarityLiveCoach/ScriptOutlineCard.swift` lines 74–87

```swift
   74      /// Which part the call is on right now.
   75      var currentID: String {
   76          if coach.status == .ready { return "opening" }
   77          let stage = coach.suggestion.stage.lowercased()
   78          let theySpoke = coach.turns.contains { $0.speaker == .prospect }
   79          if stage.contains("objection") { return "objection" }
   80          if stage.contains("goal") || stage.contains("clos") || stage.contains("ask") || stage.contains("book") { return "closing" }
   81          if stage.contains("discover") || stage.contains("question") { return "discovery" }
   82          if stage.contains("value") || stage.contains("reason") || stage.contains("why") || stage.contains("problem") { return "value" }
   83          if stage.contains("exit") { return "exit" }
   84          // Still on the opener, but they answered it: the next thing to say is why you're calling.
   85          if (stage.contains("opener") || stage.isEmpty), theySpoke, !coach.sawVoicemail, !coach.screenerActive { return "value" }
   86          return "opening"
   87      }
```

### 9.1 How a script is generated (the writer's prompt)

`ClarityLiveCoach/CampaignSelector.swift` lines 432–548

```swift
  432      static func write(segment: String, audience: String, guidance: String = "", list: Salesforce.ListView?,
  433                        onText: @escaping (String) -> Void,
  434                        onThinking: ((String) -> Void)? = nil) async throws -> String {
  435          guard let key = Keychain.read(.anthropic) else {
  436              throw ClaudeClient.APIError(message: "Add your Anthropic key first (gear menu > Setup > AI keys).")
  437          }
  438          var sample = ""
  439          if let v = list {
  440              let rows = (try? await Salesforce.fullList(object: v.object, key: v.id)) ?? []
  441              sample = rows.prefix(40).map { $0.subtitle.isEmpty ? $0.name : $0.subtitle }.joined(separator: "\n")
  442          }
  443          var client = ClaudeClient(apiKey: key)
  444          // Sonnet at medium effort: about a minute or two. Opus at high effort took 5+ minutes.
  445          client.model = "claude-sonnet-5-5"
  446          client.effort = "medium"
  447          client.maxTokens = 32000 // a full backbone script is long
  448          client.idleTimeout = 60
  449          client.totalTimeout = 300
  450          client.thinking = ["type": "adaptive", "display": "summarized"] // so the rep sees it working
  451          let year = Calendar.current.component(.year, from: Date())
  452          let system = """
  453          You are a world-class cold call script writer, using the best \(year) cold calling techniques, openers
  454          and talk tracks. You write for Clarity Consulting, a boutique Salesforce partner and Anthropic Claude
  455          partner in Portland, Oregon. A live call coach app reads your script during the call: it tracks state,
  456          walks the pick order, matches what the prospect says to a row's "Sounds like", and shows that row's "Say"
  457          line word for word. So the script must be complete and follow the skeleton below exactly.
  458  
  459          Every call segment is different. A tax firm, a law firm, a sales team and a manufacturer have different
  460          pains, words, busy seasons, tools, goals and brush-offs, so the reason, the question, discovery, the
  461          objections, voicemails, texts and LinkedIn notes are all written fresh for this segment. Never reuse a
  462          generic pitch. Before writing, think hard about this segment from the rep's description: their top pains
  463          in their own words, what they want this year, what they're proud of and afraid of, their day and busy
  464          seasons, what makes them look for help, who else they answer to, the tools they use, and the brush-offs
  465          they give every cold caller.
  466  
  467          The one thing that's the same for every segment: the ask is a free 45 minute AI and customer records
  468          health check with Oliver, our managing partner. Fill in the PLAYBOOK block at the top for this segment
  469          (avatar, titles, their words, problem lines, incentive) and use those values everywhere they appear.
  470  
  471          How great cold calls work in \(year):
  472          - Opener: honest and calm. Say it's a cold call or give the reason right away, then ask for 30 seconds.
  473            Never "how are you", never "did I catch you at a bad time".
  474          - Reason: one problem people like them have, in their words, framed as what peers deal with. Not the product.
  475          - The question: one question that sorts them into 2 to 4 tracks, so discovery fits where they are.
  476          - Discovery: one short question at a time, branching on their answer. Get the task or problem, who it hits
  477            and what it costs, in their words. At most 3 questions before playing it back.
  478          - Play it back in their words and get a yes before asking for the meeting.
  479          - Objections: a few words of agreement, then one curious question. Never argue. Respect a second firm no.
  480          - The ask: small, specific, low risk, with two real times.
  481          - Gatekeepers: sound expected, ask for help, never pitch them.
  482          - Voicemail under 20 seconds; texts and LinkedIn notes in the same voice, each a new angle.
  483          - Sound like a sharp, calm peer from their world. Short words, contractions, no jargon, no hype.
  484  
  485          Rules:
  486          - Follow the skeleton exactly: every section, in order, with the same titles. Table rows use " | "
  487            between columns, matching each table's header. Copy the sections it says to copy. Replace every note in
  488            (parentheses) with real content for this segment. Stages are named (GATE, OPEN, REASON, PROBLEM, PAIN,
  489            PLAYBACK, BRIDGE, ASK, JOIN, LOCK, HANDOFF), never numbered. Row IDs are short names, like
  490            "GATE what about", "PAIN late 1", "OBJ cost", "Q which AI", "VM1". Mark one "(default)" row per stage.
  491          - Every Say line is a real line to say out loud, never an instruction like "Show the next line".
  492          - Every Say line (voicemails, texts and LinkedIn excepted): 25 words at most, exactly one question mark
  493            and it ends with it, unless the row ends the call. Plain spoken English a 5th grader could read.
  494            Outcome first (time back, more selling, less risk), then the problem, then the fix. Technology last.
  495          - Never: an em dash, an all-caps abbreviation except AI (write "customer records", not the short form),
  496            a "$" or "%" or price, or a day or time. Times are always [Slot A] and [Slot B] (or [Slot C], [Slot D]).
  497          - Facts: only the FACTS section. Never invent a number, stat, client name, result, price or offer. If the
  498            rep's description gives a real proof point, you may use it exactly as written.
  499          - Use [slots] like [Name], [Company], [SDR], [Slot A], [Slot B], [people], [hours_week]. Use [Name] for
  500            the prospect, never he or she.
  501          - Return only the script as plain text. No markdown, no notes before or after.
  502  
  503          SKELETON:
  504          \(ScriptSkeleton.text)
  505          """
  506          let user = """
  507          Write the script for this call segment.
  508          Call segment: \(segment.isEmpty ? "Not named" : segment)
  509          The rep's description (this leads): \(audience.trimmed.isEmpty ? "Not given. Use the list below." : audience.trimmed)
  510          \(guidance.trimmed.isEmpty ? "" : "The rep's special instructions (follow these closely, work them into the script): " + guidance.trimmed)
  511          \(CallLessons.text.isEmpty ? "" : "Lessons from this team's real calls (use the ones that fit this segment; they never override the facts):\n" + CallLessons.text)
  512          \(sample.isEmpty ? "" : "Titles and companies from the Salesforce list (a hint only; the description wins):\n\(sample)")
  513          """
  514          var text = ""
  515          try await client.stream(system: system, user: user, onText: { partial in
  516              text = partial
  517              onText(partial)
  518          }, onThinking: onThinking)
  519          text = text.trimmed
  520          // Check every line against the house rules in code. Claude fixes the ones that fail, once.
  521          let issues = Guardrail.lint(script: text)
  522          guard !issues.isEmpty else { return text }
  523          let list = issues.prefix(40).map { "\($0.id) | \($0.say) | problems: \($0.problems.joined(separator: "; "))" }.joined(separator: "\n")
  524          var fixer = ClaudeClient(apiKey: key)
  525          fixer.model = "claude-sonnet-5-5"
  526          fixer.effort = "low"
  527          fixer.maxTokens = 8000
  528          let fixSystem = """
  529          You fix cold call script lines that broke the house rules. For each line, write a new line that says the
  530          same thing and passes: 25 words at most; exactly one question mark, at the end (unless it ends the call);
  531          no abbreviations in capitals except AI (say "customer records"); no em dash; no $ or % or price; no day or
  532          time (use [Slot A] or [Slot B]); none of these words: \(Guardrail.banned.joined(separator: ", ")); a real line,
  533          never an instruction. Keep [slots] as they are.
  534          Return only JSON: {"fixes": [{"old": "the exact old line", "new": "the new line"}]}
  535          """
  536          if let json = try? await fixer.json(system: fixSystem, user: list),
  537             let fixes = json["fixes"] as? [[String: Any]] {
  538              for f in fixes {
  539                  guard let old = f["old"] as? String, let new = f["new"] as? String, !old.isEmpty,
  540                        Guardrail.problems(new, endsCall: !new.hasSuffix("?")).filter({ !$0.contains("question") }).isEmpty else { continue }
  541                  text = text.replacingOccurrences(of: old, with: new)
  542              }
  543              onText(text)
  544          }
  545          let left = Guardrail.lint(script: text).count
  546          await MainActor.run { ActivityLog.add("Script writer: \(issues.count) lines broke the rules, \(issues.count - left) fixed, \(left) left") }
  547          return text
  548      }
```

### 9.2 The backbone skeleton the writer must follow

`ClarityLiveCoach/ScriptSkeleton.swift` lines 1–222

```text
    1  import Foundation
    2  
    3  /// The bones every generated cold call script is built on: section titles, table layouts, how the
    4  /// stages flow, and the rules that are the same across Clarity. No script lines: those are written
    5  /// fresh for each call segment. The only thing every segment shares is the ask: a free 45 minute
    6  /// CRM or AI health check with Oliver.
    7  enum ScriptSkeleton {
    8      static let text = #"""
    9  COLD CALL BACKBONE v3
   10  Call segment: [segment name]
   11  
   12  PLAYBOOK
   13  (Fill in for this segment. One playbook = one avatar + one offer.)
   14  avatar_name: (who they are, like "Tax firm owners")
   15  avatar_titles: (3 to 6 real titles)
   16  avatar_language: (8 to 15 words and phrases they really use about their work)
   17  offer_name: AI and customer records health check
   18  offer_length: 45 minutes
   19  host_name: Oliver
   20  host_title: our managing partner
   21  host_years: over a decade
   22  incentive: (lunch for the team, or "none")
   23  incentive_caveat: If they can't accept gifts, drop the lunch and keep the meeting.
   24  problem_lines: (one short problem line per title type, in their words)
   25  
   26  1. JOB
   27  Goal: a 45 minute [offer_name] with the decider, on the calendar, with every decider invited.
   28  Best outcome: meeting booked with the decider and other deciders joining.
   29  Second best: callback time set with the decider, or a warm handoff to the right person.
   30  
   31  2. OUTPUT CONTRACT
   32  (Copy as written.)
   33  Reply as JSON, "say" first: {"say": "...", "stage": "STAGE", "save": {"slot": "value"}, "flags": []}
   34  Flags: end_call, do_not_call, send_invite, send_email, book_callback, use_directory, needs_human.
   35  One line, 25 words at most. Voicemails are the only exception.
   36  End with a question unless flags has end_call. One question only.
   37  
   38  3. INPUTS
   39  (Copy as written.)
   40  Each turn the coach gets: PROSPECT (name, title, company, notes), CALENDAR (Slot A to Slot D, real open
   41  times in the prospect's time zone), STATE (saved slots and counters), EVENT, and the full TRANSCRIPT.
   42  
   43  4. PICK ORDER
   44  (Copy as written.) Check in this order. Use the first match.
   45  Opt out or angry
   46  Second no
   47  Voicemail, phone tree or call screen
   48  Gatekeeper
   49  Meeting yes (wants a time, the calendar or the invite)
   50  Info request (send me something: NOT a meeting yes)
   51  Direct question
   52  Objection
   53  Stage row
   54  Stage default
   55  
   56  5. RULES
   57  (Copy as written. Add up to 3 for this segment.)
   58  Pick the row by meaning. "Sounds like" phrases are examples.
   59  Save every name, number, tool and time the prospect says, at any stage.
   60  Never ask for something the prospect already said.
   61  Two things at once: save both, answer the one higher in the pick order.
   62  Math only with numbers the prospect said. Missing a number: skip the math.
   63  At most 3 pain questions before PLAYBACK.
   64  Two short answers in a row: skip BRIDGE.
   65  Times come only from CALENDAR as [Slot A] and [Slot B]. Never make up a day or time.
   66  Push through once on a no. On the second no, end politely.
   67  Opt out: say the G1 line, set do_not_call, end. It is written in Salesforce for real.
   68  "Send me info" is not a meeting. Send the email, then ask once for a time.
   69  
   70  6. VOICE
   71  (Copy as written. Add 1 or 2 lines for how this segment talks.)
   72  Calm and plain. Like a peer, not a fan.
   73  Outcome first, then the problem, then the fix. Technology last.
   74  Use their words back to them.
   75  Say their first name at the open and the close only.
   76  
   77  7. NEVER SAY
   78  (Copy as written. Add anything this segment would find off-putting.)
   79  Any all-caps abbreviation except AI. Say "customer records" or "customer system", not the short form.
   80  Filler: awesome, super excited, beautiful day, my friend, brother, to be honest
   81  selected, assigned, referred, certified, replace, never messes up
   82  "I left a message" unless one was left
   83  Anthropic sent us or asked for the call
   84  roadmap, transformation, maturity, enablement, digital
   85  Any price, dollar amount, percent or survey number
   86  A client name
   87  That a tool works with ours, unless it is in FACTS
   88  Em dashes
   89  
   90  8. FACTS
   91  (The only facts. Copy as written. Add only what is true for every Clarity client.)
   92  Clarity Consulting. Anthropic partner. Salesforce partner. Based in Portland, Oregon.
   93  [host_name], [host_title], has done this kind of work for [host_years].
   94  After every client call, AI can fill in the customer record fields.
   95  Works with any customer system, or none.
   96  We build custom connectors so Claude works inside tools a team already uses.
   97  The [offer_name] is free and takes [offer_length].
   98  In it, [host_name] looks at where the hours go, who owns the work and what's in the way.
   99  They leave with the top 3 things to fix first.
  100  Unknown question: "Good question. Oliver can answer that on the call. Want to grab a time?"
  101  
  102  9. STATE
  103  (Copy as written. Name the tracks and slots for this segment.)
  104  line_type: screen, tree, gatekeeper, decider, voicemail
  105  track: (2 to 4 tracks from the PROBLEM question, named for this segment)
  106  Counters kept by the app: short_answers, voicemail_count, pain_questions, total_hours_week
  107  Counters kept by the coach: no_count (0, 1, 2), problem_named (yes, no), confirmed (yes, no), track
  108  Slots: name, role, company, (the tools, numbers and details this segment's PAIN rows collect), hours_week,
  109  people, other_deciders, email, direct_line, callback_time, meeting_slot, message_left
  110  
  111  10. GLOBALS
  112  ID | Sounds like | Say | Then
  113  (Write every row for this segment.
  114  G1 opt out: honest, one line, flags do_not_call + end_call.
  115  G2 angry: one calm line, end_call.
  116  G3 second no: polite exit, end_call.
  117  G4 call screen: one line with [SDR], Clarity Consulting and the reason, then wait.
  118  G5 phone tree: Say "Use the name directory. No voicemail on menus.", flags use_directory.
  119  G6 voicemail: the next voicemail by voicemail_count, end_call.
  120  G7 wrong person: get the right name and direct_line, HANDOFF.
  121  G8 left the company: ask who took over, HANDOFF.
  122  G9 bad time: offer [Slot A] or [Slot B] for a callback, save callback_time, flags book_callback.
  123  G10 meeting yes: straight to ASK with [Slot A] or [Slot B], confirmed = yes.
  124  G11 info request: "Happy to. What's the best email?", flags send_email, then one ask for a time.)
  125  
  126  11. STAGES
  127  For every stage: a short line on when it starts, then a table. Mark exactly one row per stage as
  128  the default with "(default)" after its ID. That's the line the app shows when nothing else fits.
  129  ID | Sounds like | When | Say | Then
  130  
  131  GATE
  132  Never pitch. Never ask about their systems.
  133  (Rows: open, what's it about, are they expecting you, not in, direct line, take a message, email, not the
  134  decider, transfer (Say "Show nothing", next OPEN), default.)
  135  
  136  OPEN
  137  (Rows: confirm it's them, permission-based open, yes (next REASON), who is this, busy (G9), early no
  138  (no_count +1), default.)
  139  
  140  REASON
  141  One line: a problem people like them have, in their words, framed as what peers deal with. Not the product.
  142  (1 to 3 rows, split by title type using problem_lines. Then next PROBLEM right away.)
  143  
  144  PROBLEM
  145  One question that sorts them into the tracks in STATE. (Next PAIN.)
  146  
  147  PAIN
  148  One short question at a time, per track. Count pain_questions. Set problem_named = yes when (the signals
  149  that mean this segment has a real problem). Collect hours_week and people when you can.
  150  (A small table per track, plus "any track" rows: we're good, nothing, don't know, a tool name, default.)
  151  
  152  PLAYBACK
  153  Enter when problem_named = yes. Use their words.
  154  (Rows: math (only with numbers they said: [people] people at [hours_week] hours is [total_hours_week]
  155  hours a week), no math, yes (confirmed = yes; next BRIDGE, or ASK if short_answers is 2 or more), fix it, small.)
  156  
  157  BRIDGE
  158  Skip if short_answers is 2 or more.
  159  (Rows: ask what fixing it would mean to them, answer (next ASK).)
  160  
  161  ASK
  162  Only when confirmed = yes. Always the free [offer_length] [offer_name] with [host_name], [host_title],
  163  with two real times: [Slot A] or [Slot B].
  164  (Rows: ask, yes (next JOIN), what is it, too long, neither time ([Slot C] or [Slot D]), send info (G11),
  165  default.)
  166  
  167  JOIN
  168  Who else decides? (Rows: ask who else should join, names given (save other_deciders, next LOCK), just me
  169  (next LOCK).)
  170  
  171  LOCK
  172  Confirm the time and email, flags send_invite. (Rows: email, confirm time, invite sent (end_call),
  173  invite failed (one line: we'll email it, end_call).)
  174  
  175  HANDOFF
  176  Handed to someone else. (Rows: who, direct line, warm intro line for the new person, end.)
  177  
  178  12. OBJECTIONS
  179  Match at any stage after OPEN. A few words of agreement, then one curious question.
  180  ID | Sounds like | Say | Then
  181  (15 to 20 this segment really uses. Include: not interested (no_count +1, two branches), send an email
  182  (G11), cost (it's free), what's the catch, we tried AI, we do it in house, we have a partner, security,
  183  not urgent, busy season, talk to my partner, group decision, too small, no budget, can't accept gifts
  184  (incentive_caveat).)
  185  
  186  13. QUESTIONS
  187  Answer, then back to the last stage question.
  188  ID | Sounds like | Say | Then
  189  (what do you do, are you selling, who are you, who have you worked with (never name clients), where are
  190  you based, how long, which AI, does it work with [tool], how long to set up, why us, is this AI, plus
  191  this segment's own. Anything not in FACTS: the unknown-question line.)
  192  
  193  14. VOICEMAILS
  194  Personal voicemail only. One per attempt, in order by voicemail_count. Under 20 seconds.
  195  ID | Say
  196  (VM1 to VM3. Each a new angle. VM3 is the last try.)
  197  
  198  TEXTS
  199  ID | When | Send
  200  (T1 after no answer on try 1. T2 after try 2.)
  201  
  202  LINKEDIN
  203  ID | When | Send
  204  (L1 connection note under 200 characters. L2 accepted. L3 they reply (two real times). L4 no reply in 4 days.)
  205  
  206  15. NOISE MAP
  207  Heard word -> real word. (Copy these. Add this segment's tools and terms speech-to-text could mishear.)
  208  cloud, quad, claw, clod, clyde -> Claude
  209  enanthropic, and profit -> Anthropic
  210  clearity, charity -> Clarity
  211  serum, C R M -> customer system
  212  sales force -> Salesforce
  213  olivier, oliva -> Oliver
  214  
  215  16. FAST PATH PHRASES
  216  (Copy and add. The app matches these in code, before Claude.)
  217  opt_out: take me off your list, don't call me again, remove me, stop calling, do not call
  218  voicemail: leave a message, after the tone, after the beep, not available, record your message
  219  phone_tree: press 1, for sales press, dial by name, directory, if you know your party's extension
  220  """#
  221  }
  222  
```

## 10. THINK on the card, and every fallback that replaces it

THINK is requested by the prompt (`Think.promptLine`), parsed into `Suggestion.think`, and chosen for display by `Think.primary`. SAY is always generated alongside it.

**THINK is replaced by SAY when any of these is true** (all in `Think.swift` / `CoachView.swift`):
1. THINK mode is off (Settings switch, `Think.enabled`).
2. The line is an approved script row (`rowTag != nil`) or an instant script answer: EXACT, always SAY.
3. THINK is missing, under 2 words, over 16 words, or starts with `<`.
4. THINK contains coaching jargon (`Think.jargon`).
5. THINK has a question followed by more text (a question to say plus an instruction).
6. THINK has the rep claiming the prospect's role (`RoleCheck`).
7. THINK is a question but SAY shares no content word with it (`Think.agrees`).
8. The rep presses the full-line control (⌘⇧L).
9. The card is not a normal live reply: nudge, history view, opener, voicemail, screener (`thinkActive` in `CoachView`).

THINK is **not** validated by a second model call and is not checked against the conversation beyond items 3–7. The conversation checks in `lineProblems` (section 4.4) test SAY and `MOVE`, not THINK.


`CoachCore/Think.swift` lines 1–147

```swift
    1  import Foundation
    2  
    3  /// THINK mode (on by default): the card shows one short thought the rep can say
    4  /// as-is or in their own words. The full SAY line stays one shortcut away. Script rows always show in full.
    5  public enum Think {
    6      public static let defaultsKey = "thinkCoach"
    7      /// On unless turned off in Settings.
    8      public static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    9  
   10      /// The prompt line asking for the thought. Empty when THINK mode is off, so the live prompt is unchanged.
   11      public static func promptLine(enabled: Bool) -> String {
   12          guard enabled else { return "" }
   13          return """
   14          THINK: <one quick coaching nudge for the rep, usually 5 to 12 simple words>
   15            THINK rules (a skilled coach whispering the next move, not a script):
   16            - Pick the MOVE first, then write THINK for that move. THINK and SAY must be the same move and the same question.
   17            - Before you write it, decide the ONE most valuable thing still unknown: a concrete example of something
   18              broad, the cause of a problem they confirmed, how they do it today, what it costs them, who decides, or
   19              (when interest and fit are real) a meeting. Not a fixed order. Pick what this conversation needs.
   20            - Ask about their actual tools, process and words. Never assume a problem because it is common in their industry.
   21            - Usually ONE short question the rep can say aloud. Example ladder, they said "our team won't use Salesforce":
   22              weak "What's your biggest challenge?" / better "What's stopping your team from using Salesforce?" /
   23              best when you need the root cause "What happens when your team tries to use it?" (it asks for a real example).
   24            - When a question is the wrong move, a short instruction instead: they asked what the call is about
   25              -> "Explain the free AI health check." They said no again -> "Thank them and end the call." They are
   26              ending the call -> "Thank them. Don't push." Never both a question and an instruction in one THINK.
   27            - Answer their direct question first. An objection ("we use Gong", "no time") can get one relevant question.
   28              A clear no ("not interested", "not a fit") gets no sales question: acknowledge, at most offer an easy exit.
   29            - Never repeat a question they already answered, declined or deflected. Skip what the call already established.
   30            - Never vague coaching words: no "explore", "probe", "find the gap", "handle the objection", "qualify".
   31            - Everyday words: "your team", "call notes", "follow-ups". Never "your reps".
   32            - Good: "Does Gong handle your follow-ups too?"  Bad: "Who's the right person? Ask for a name."
   33            - Good: "Who handles sales tools there?"  Bad: "Explore whether Gong handles CRM updates."
   34  
   35          """
   36      }
   37  
   38      /// Coaching jargon that needs translating mid-call: falls back to SAY.
   39      static let jargon = ["explore", "probe", "dig ", "drive ", "uncover", "leverage", "qualify", "find the gap",
   40                           "handle the objection", "handle objection", "identify friction", "friction"]
   41  
   42      /// Words a THINK that states (not asks) a pain would be assuming, unless the prospect said them.
   43      static let assumedPain = ["wasting", "struggling", "losing hours", "drowning", "frustrated", "painful", "a mess"]
   44  
   45      /// A usable thought on its own, or nil (then the card falls back to SAY).
   46      public static func valid(_ think: String) -> String? {
   47          let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
   48          let words = t.split(whereSeparator: { $0 == " " }).count
   49          guard words >= 2, words <= 16, !t.hasPrefix("<"), !t.uppercased().hasPrefix("SAY") else { return nil }
   50          let low = t.lowercased()
   51          if jargon.contains(where: { low.contains($0) }) { return nil }
   52          // A question to say plus an instruction to the rep ("Who's the right person? Ask for a name.").
   53          if let q = t.firstIndex(of: "?"), t[t.index(after: q)...].contains(where: { $0.isLetter }) { return nil }
   54          if RoleCheck.speaksAsProspect(t) { return nil }
   55          return t
   56      }
   57  
   58      /// Why this THINK should not reach the screen in this conversation (empty = fine). Rules only, no model call.
   59      /// `sayLine` is the SAY that came with it. Each problem string is also what a retry is told to fix.
   60      public static func problems(think: String, say: String, move: String, intent: ConversationIntent, objectionKind: String?,
   61                                  latestProspect: String, recentText: String, scriptText: String, answeredQuestions: [String]) -> [String] {
   62          let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
   63          guard !t.isEmpty else { return ["THINK is missing: write one short coaching nudge"] }
   64          guard valid(t) != nil else { return ["THINK isn't usable: one clear move, 2 to 16 simple words, no jargon, no question plus instruction"] }
   65          var out: [String] = []
   66          let isQuestion = t.hasSuffix("?")
   67          // They're done: no question to ask.
   68          if isQuestion, [.ending, .optOut].contains(intent) {
   69              out.append("THINK asks a question but they're ending the call: thank them, don't push")
   70          }
   71          // A clear no: no sales question. The only question allowed is the exit itself (move close: "Can I send one email?").
   72          if isQuestion, intent == .rejection, move != "close" {
   73              out.append("THINK asks a question after a clear no: acknowledge it, at most offer an easy exit")
   74          }
   75          if intent == .rejection, ["discover", "clarify", "objection"].contains(move) {
   76              out.append("MOVE \(move) after a clear no: acknowledge or close instead")
   77          }
   78          // A direct question from them comes first: THINK must answer it, not discover.
   79          if intent == .question, move == "discover" {
   80              out.append("they asked a direct question: THINK must answer it first (MOVE answer), not start discovery")
   81          }
   82          // Discovery needs a question; a pure statement or instruction for MOVE discover is the wrong coaching.
   83          if move == "discover", !isQuestion {
   84              out.append("MOVE is discover but THINK isn't a question: write the one question to ask")
   85          }
   86          if isQuestion {
   87              // Already answered: same meaning as a question the rep asked and got an answer to.
   88              if let again = answeredQuestions.first(where: { Repeats.same($0, t) }) {
   89                  out.append("THINK repeats a question already answered: \"\(again)\"")
   90              }
   91              // Unrelated topic: nothing in it comes from this conversation or the script.
   92              let mine = Repeats.meaning(t)
   93              if !mine.isEmpty {
   94                  let known = Repeats.meaning(recentText).union(Repeats.meaning(scriptText))
   95                  if mine.intersection(known).isEmpty { out.append("THINK is about something that hasn't come up: ground it in what they said") }
   96              }
   97          } else {
   98              // States a pain as theirs when they never said it.
   99              let low = t.lowercased(), said = latestProspect.lowercased() + " " + recentText.lowercased()
  100              if let w = assumedPain.first(where: { low.contains($0) && !said.contains($0) }) {
  101                  out.append("THINK assumes a problem they haven't named (\"\(w)\"): ask, don't state it")
  102              }
  103          }
  104          if !agrees(think: t, say: say, move: move) {
  105              out.append("THINK and SAY aren't the same move: SAY should say what THINK asks or explains")
  106          }
  107          return out
  108      }
  109  
  110      /// First word class of a question: its wh-word, or "yn" for a yes/no question.
  111      static func questionClass(_ q: String) -> String {
  112          let first = q.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
  113          return ["what", "who", "how", "why", "when", "where", "which"].contains(first) ? first : "yn"
  114      }
  115  
  116      /// THINK and SAY must be the same move. Not "share any word": the same kind of question, and most of
  117      /// THINK's meaning inside SAY's question; or, for an instruction, at least one shared meaning word.
  118      public static func agrees(think: String, say: String, move: String = "") -> Bool {
  119          let t = think.trimmingCharacters(in: .whitespacesAndNewlines)
  120          if t.hasSuffix("?") {
  121              // SAY's questions: the one that best matches THINK.
  122              let sayQuestions = QuestionTracker.questions(in: say)
  123              guard !sayQuestions.isEmpty else { return false }
  124              let mine = Repeats.meaning(t)
  125              return sayQuestions.contains { q in
  126                  guard questionClass(q) == questionClass(t) else { return false }
  127                  let theirs = Repeats.meaning(q)
  128                  guard !mine.isEmpty else { return true }
  129                  return Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.5
  130              }
  131          }
  132          // An instruction describes the move; SAY carries it out. Discovery needs a question, so no.
  133          if move == "discover" { return false }
  134          // Stop or close: SAY must not go on asking.
  135          if ["acknowledge", "close"].contains(move) { return !say.contains("?") }
  136          // Answer or explain: SAY must be about the same thing.
  137          let mine = Repeats.meaning(t)
  138          return mine.isEmpty || !mine.intersection(Repeats.meaning(say)).isEmpty
  139      }
  140  
  141      /// What the big line shows. Script rows (exact) and missing or bad thoughts show SAY; the rep can ask for SAY anytime.
  142      public static func primary(think: String, say: String, exact: Bool, enabled: Bool, showFull: Bool, move: String = "") -> String {
  143          guard enabled, !exact, !showFull, let t = valid(think), agrees(think: t, say: say, move: move) else { return say }
  144          return t
  145      }
  146  }
  147  
```

`ClarityLiveCoach/CoachView.swift` lines 1060–1080

```swift
 1060                  }
 1061              } else if liveCardOpen {
 1062              lineText(inTour && coach.status == .ready ? TourSample.line
 1063                   : coach.suggestion.say.isEmpty
 1064                   ? (Keychain.read(.anthropic) == nil ? "Almost there. Click the gear, then Set up, and upload your keys file." : "Getting your line ready...")
 1065                   : cardLine, emphasized: false) // frozen for the model test: plain line
 1066                  .font(lineFont)
 1067                  .lineSpacing(2)
 1068                  .fixedSize(horizontal: false, vertical: true)
 1069                  .foregroundStyle(lineIsSoft ? Color.secondary : Color.primary)
 1070                  .opacity(coach.historyIndex == nil ? 1 : 0.6)
 1071                  // Between calls, click the opener to edit it.
 1072                  .onTapGesture {
 1073                      guard coach.status == .ready, coach.kind == .opener, !inTour else { return }
 1074                      openerDraft = coach.scriptOpenerLine() ?? coach.suggestion.say
 1075                      editingOpener = true
 1076                  }
 1077                  .help(coach.status == .ready && coach.kind == .opener ? "Click to edit your opener" : "")
 1078              // THINK mode: one thought on the card; the full line only when the rep asks (⌘⇧L).
 1079              if thinkShown || showFullLine {
 1080                  Button(showFullLine ? "Back to the short thought" : "Full line (⌘⇧L)") { showFullLine.toggle() }
```

`ClarityLiveCoach/CoachView.swift` lines 1147–1160

```swift
 1147      private var cardLabel: String {
 1148          if inTour && coach.status == .ready { return "WHEN THEY PICK UP" }
 1149          if coach.historyIndex != nil { return "EARLIER LINE" }
 1150          if coach.suggestion.nudge { return "IF IT GOES QUIET" }
 1151          switch coach.kind {
 1152          case .opener: return "WHEN THEY PICK UP"
 1153          case .screener: return "A ROBOT ANSWERED · SAY THIS"
 1154          case .voicemail: return "VOICEMAIL · WAIT FOR THE BEEP"
 1155          case .reply:
 1156              // THINK mode: no label while a thought is up. If THINK didn't hold up, the full line shows and says so.
 1157              if thinkActive { return coach.suggestion.rowTag != nil ? "EXACT" : (thinkShown ? "" : "SAY THIS") }
 1158              return coach.suggestion.rowTag != nil ? "SAY THIS · EXACT" : "SAY THIS" // frozen for the Haiku vs Sonnet test
 1159          }
 1160      }
```

`CoachCore/LineLook.swift` lines 1–41

```swift
    1  import Foundation
    2  
    3  /// How a line looks on the card: a one-glance move label, and which part to make stand out.
    4  /// Display only. It never changes the words, the model, or when a line shows.
    5  public enum LineLook {
    6      /// The label above the line, from the move the model already picks. Empty move = "SAY THIS" (no guessing).
    7      public static func label(move: String, exact: Bool) -> String {
    8          let base: String
    9          switch move.lowercased().trimmingCharacters(in: .whitespaces) {
   10          case "discover": base = "ASK"
   11          case "clarify": base = "CHECK WHAT THEY MEANT"
   12          case "answer": base = "ANSWER THEM"
   13          case "acknowledge": base = "ACKNOWLEDGE"
   14          case "objection": base = "HANDLE THE PUSHBACK"
   15          case "close": base = "CLOSE"
   16          default: base = "SAY THIS"
   17          }
   18          return exact ? base + " · EXACT" : base
   19      }
   20  
   21      /// The line split so its one question stands out: (before, question, after).
   22      /// Only when the line has exactly one sentence ending in "?" and some other text too.
   23      /// Anything else returns nil and the whole line shows plain. No guessing.
   24      public static func emphasis(_ say: String) -> (before: String, key: String, after: String)? {
   25          let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
   26          guard text.filter({ $0 == "?" }).count == 1, let q = text.firstIndex(of: "?") else { return nil }
   27          // Start of the question's sentence: just after the last ". ", "! " before the "?".
   28          var start = text.startIndex
   29          var i = text.startIndex
   30          while i < q {
   31              let next = text.index(after: i)
   32              if ".!".contains(text[i]), next < q, text[next] == " " { start = text.index(after: next) }
   33              i = next
   34          }
   35          let end = text.index(after: q)
   36          let before = String(text[..<start]), key = String(text[start..<end]), after = String(text[end...])
   37          guard !before.trimmingCharacters(in: .whitespaces).isEmpty || !after.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
   38          return (before, key, after)
   39      }
   40  }
   41  
```

## 11. Haiku vs Sonnet

Both are called through the same `ask(...)`. Differences:

| | Haiku 5.5 | Sonnet 5.5 |
|---|---|---|
| Chosen how | `LiveCoach.callModel`, alternated per call by `pickModelForNextCall()` (even calls) | the other calls; also used for any **space-bar fresh line** (`nextAskModel`, `CoachModel+Lines.swift` line 88) |
| Thinking | `{"type": "disabled"}` | `{"type": "between_tools"}` (the way Sonnet 5.5 is run with thinking off) |
| Effort / tokens / timeouts | `low`, 120 max tokens, 8 s idle, 15 s total | identical |
| Opener, voicemail, summary, phone tree | always Haiku (`CoachSpeed.current == .fastest`) | not used |
| Script writer | not used | Sonnet at medium effort, 32,000 max tokens, adaptive thinking (`ScriptWriter.write`) |
| Prompts, parsing, checks, display rules | identical | identical |

There is **no** Haiku-specific or Sonnet-specific prompt text, parser, or check. The only code that depends on the model name is the client configuration below and the model-test bookkeeping in `show()` (`testLineCounted`), which leaves out space-bar lines, script answers and opt-out lines from the Haiku vs Sonnet comparison.


`ClarityLiveCoach/LiveCoach.swift` lines 4–45

```swift
    4  /// The live line: Haiku, fast and short, checked in code before it shows.
    5  enum LiveCoach {
    6      /// This call's live-line model: calls alternate Haiku and Sonnet, to compare them on real calls.
    7      static var callModel = "claude-haiku-5-5"
    8      static let testModels = ["claude-haiku-5-5", "claude-sonnet-5-5"]
    9  
   10      /// The next call's model (alternates, and remembers across app restarts).
   11      static func pickModelForNextCall() -> String {
   12          let n = UserDefaults.standard.integer(forKey: "abCallCount")
   13          UserDefaults.standard.set(n + 1, forKey: "abCallCount")
   14          return testModels[n % testModels.count]
   15      }
   16  
   17      static func client(_ key: String, model: String? = nil) -> ClaudeClient {
   18          let model = model ?? callModel
   19          var c = ClaudeClient(apiKey: key)
   20          c.model = model
   21          c.effort = "low"
   22          c.maxTokens = 120          // SAY + CUE + STAGE: a 1 to 2 sentence line
   23          c.idleTimeout = 8
   24          c.totalTimeout = 15
   25          if model.contains("haiku") {
   26              c.thinking = ["type": "disabled"] // this model takes no temperature setting
   27          } else {
   28              c.thinking = ["type": "between_tools"] // Sonnet with thinking off
   29          }
   30          return c
   31      }
   32  
   33      // MARK: Opt out, handled in code (no AI)
   34  
   35      static func isOptOut(_ text: String, isFinal: Bool = true) -> Bool { OptOut.matches(text, isFinal: isFinal) }
   36  
   37      static let optOutLine = "Understood. I'll take you off our list right now. Have a good day."
   38  
   39      /// Last resort when a line fails the check twice: smallest safe fix.
   40      static func sanitize(_ say: String) -> String {
   41          var s = say.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: ",")
   42          s = LineRepair.oneQuestion(s)
   43          return LineRepair.trimToFit(s, max: LineBudget.checkMax) // whole sentences, never a fragment (M7)
   44      }
   45  }
```

`ClarityLiveCoach/Claude.swift` lines 131–163

```swift
  131  /// How the live coach trades polish for speed. Pick in the gear menu.
  132  enum CoachSpeed: String, CaseIterable, Identifiable {
  133      case balanced, fastest // "best" (Opus) is off for now; a saved "best" falls back to balanced
  134  
  135      var id: String { rawValue }
  136  
  137      var label: String {
  138          switch self {
  139          case .balanced: return "Fast (best for most people)"
  140          case .fastest: return "Fastest"
  141          }
  142      }
  143  
  144      static var current: CoachSpeed {
  145          .fastest // fixed while the model test runs: openers stay quick (Haiku), and no setting skews the test
  146      }
  147  
  148      func client(apiKey: String) -> ClaudeClient {
  149          var c = ClaudeClient(apiKey: apiKey)
  150          c.effort = "low"
  151          c.idleTimeout = 10 // a live line that stalls is useless; the rep keeps the last one
  152          c.totalTimeout = 30
  153          switch self {
  154          case .balanced:
  155              c.model = "claude-sonnet-5-5"
  156              c.thinking = ["type": "between_tools"] // Sonnet 5.5's way to turn thinking off
  157          case .fastest:
  158              c.model = "claude-haiku-5-5"
  159              c.thinking = ["type": "disabled"]
  160          }
  161          return c
  162      }
  163  }
```

`ClarityLiveCoach/Claude.swift` lines 25–100

```swift
   25      /// Calls onText with all the text so far, each time more arrives. Cancel the surrounding Task to stop early.
   26      /// onThinking gets the thinking summary so far, when `thinking` asks for display "summarized".
   27      func stream(system: String, user: String, onText: @escaping (String) -> Void,
   28                  onThinking: ((String) -> Void)? = nil, onUsage: (([String: Int]) -> Void)? = nil,
   29                  onModel: ((String) -> Void)? = nil) async throws {
   30          var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
   31          request.httpMethod = "POST"
   32          request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
   33          request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
   34          request.setValue("application/json", forHTTPHeaderField: "content-type")
   35  
   36          var body: [String: Any] = [
   37              "model": model,
   38              "max_tokens": maxTokens,
   39              "stream": true,
   40              "output_config": ["effort": effort],
   41              // The rules and campaign never change during a call, so they are cached.
   42              "system": [["type": "text", "text": system + "\n\n" + ReadingLevel.rule, "cache_control": ["type": "ephemeral"]]],
   43              "messages": [["role": "user", "content": user]],
   44          ]
   45          if let thinking { body["thinking"] = thinking }
   46          // temperature is left out on purpose: the newest models reject it (error 400).
   47          if model.hasPrefix("claude-opus") || model.hasPrefix("claude-fable")
   48              || (model == "claude-sonnet-5-5" && thinking?["type"] != "between_tools") {
   49              // If a safety check declines, the API retries on a fallback model in the same call.
   50              request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
   51              body["fallbacks"] = "default"
   52          }
   53          request.httpBody = try JSONSerialization.data(withJSONObject: body)
   54  
   55          let config = URLSessionConfiguration.default
   56          config.timeoutIntervalForRequest = idleTimeout
   57          config.timeoutIntervalForResource = totalTimeout
   58          let session = URLSession(configuration: config)
   59          defer { session.finishTasksAndInvalidate() }
   60          let (bytes, response) = try await session.bytes(for: request)
   61          guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from Claude") }
   62          guard http.statusCode == 200 else {
   63              var text = ""
   64              for try await line in bytes.lines { text += line }
   65              throw APIError(message: "Claude error \(http.statusCode): \(text.prefix(300))")
   66          }
   67  
   68          var full = ""
   69          var thought = ""
   70          var usage: [String: Int] = [:]
   71          defer { if !usage.isEmpty { onUsage?(usage) } }
   72          for try await line in bytes.lines {
   73              guard line.hasPrefix("data: "),
   74                    let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
   75                    let type = json["type"] as? String else { continue }
   76              if type == "content_block_delta",
   77                 let delta = json["delta"] as? [String: Any],
   78                 delta["type"] as? String == "text_delta",
   79                 let text = delta["text"] as? String {
   80                  full += text
   81                  onText(full)
   82              } else if type == "content_block_delta", let onThinking,
   83                        let delta = json["delta"] as? [String: Any],
   84                        delta["type"] as? String == "thinking_delta",
   85                        let text = delta["thinking"] as? String {
   86                  thought += text
   87                  onThinking(thought)
   88              } else if type == "message_start", let m = json["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
   89                  // The model that actually answered (differs from the one asked for on a fallback).
   90                  if let served = m["model"] as? String { onModel?(served) }
   91                  // Input side: plain input, cache reads (cheap, fast) and cache writes.
   92                  for k in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] { if let v = u[k] as? Int { usage[k] = v } }
   93              } else if type == "message_delta", let u = json["usage"] as? [String: Any], let out = u["output_tokens"] as? Int {
   94                  usage["output_tokens"] = out
   95              } else if type == "error" {
   96                  let error = json["error"] as? [String: Any]
   97                  throw APIError(message: (error?["message"] as? String) ?? "Claude stream error")
   98              }
   99          }
  100      }
```

`CoachCore/CoachCore.swift` lines 1195–1214

```swift
 1195  /// Haiku vs Sonnet scoreboard math: is a difference real or luck?
 1196  public enum ModelTest {
 1197      /// Two-proportion z score. |z| >= 1.96 is about 95% sure the difference is real.
 1198      public static func z(_ a: Int, of n1: Int, vs b: Int, of n2: Int) -> Double {
 1199          guard n1 > 0, n2 > 0 else { return 0 }
 1200          let p1 = Double(a) / Double(n1), p2 = Double(b) / Double(n2)
 1201          let p = Double(a + b) / Double(n1 + n2)
 1202          let se = (p * (1 - p) * (1 / Double(n1) + 1 / Double(n2))).squareRoot()
 1203          return se == 0 ? 0 : (p1 - p2) / se
 1204      }
 1205  
 1206      /// "Haiku wins", "Sonnet wins" or "too close to call yet".
 1207      public static func verdict(_ a: Int, of n1: Int, vs b: Int, of n2: Int, names: (String, String)) -> String {
 1208          let score = z(a, of: n1, vs: b, of: n2)
 1209          if n1 < 20 || n2 < 20 { return "not enough calls yet (need 20+ each)" }
 1210          if score >= 1.96 { return "\(names.0) wins (95% sure)" }
 1211          if score <= -1.96 { return "\(names.1) wins (95% sure)" }
 1212          return "too close to call yet"
 1213      }
 1214  }
```

### 11.1 Small helpers the decision path calls

`ClarityLiveCoach/CoachTypes.swift` lines 168–172

```swift
  168  func isMeaningful(_ text: String) -> Bool {
  169      text.lowercased()
  170          .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
  171          .contains { !$0.isEmpty && !filler.contains($0) }
  172  }
```

`CoachCore/CoachCore.swift` lines 888–919

```swift
  888  /// The rep asked a yes/no question ("Can I get 30 seconds?", "Does that sound familiar?", "...yeah?"):
  889  /// the line for "yes" can be written before they answer. Open questions ("What do you use?") aren't.
  890  public enum RepQuestion {
  891      static let closedStarts: Set<String> = ["can", "could", "would", "will", "do", "does", "did", "is", "are", "was",
  892          "were", "have", "has", "mind", "may", "should", "okay", "ok", "sound", "fair", "right", "yeah", "correct", "cool", "make"]
  893  
  894      /// The last question in what the rep said, if it's a yes/no question.
  895      /// Check-ins ("Still with me?") aren't a real ask: a "yeah" to them isn't a yes to anything.
  896      static let checkIns = ["still with me", "you there", "can you hear me", "are you there", "did i lose you", "still there"]
  897  
  898      /// Questions often come through with no "?" ("You guys use Salesforce right"). Treat a tag ending as one.
  899      public static func asQuestion(_ text: String) -> String {
  900          let t = text.trimmingCharacters(in: .whitespaces)
  901          guard !t.hasSuffix("?") else { return t }
  902          let l = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!, "))
  903          let tags = [" right", " correct", " yeah", " yes", " no", " true", " fair"]
  904          return tags.contains(where: { l.hasSuffix($0) }) ? l + "?" : t
  905      }
  906  
  907      public static func closedQuestion(in raw: String) -> String? {
  908          let t = asQuestion(raw)
  909          guard t.hasSuffix("?") else { return nil }
  910          if checkIns.contains(where: { t.lowercased().contains($0) }) { return nil }
  911          let sentence = t.dropLast().split(whereSeparator: { ".?!".contains($0) }).last.map(String.init) ?? ""
  912          var words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
  913          while let w = words.first, ["so", "and", "but", "well", "hey", "um", "uh", "like", "just"].contains(w) { words.removeFirst() }
  914          guard let first = words.first else { return nil }
  915          // A tag question ("You guys use Salesforce, right") is yes/no whatever its first word.
  916          let tagged = ["right", "correct", "yeah", "true", "huh"].contains(words.last ?? "") && words.count > 2
  917          return tagged || closedStarts.contains(first) ? sentence.trimmingCharacters(in: .whitespaces) + "?" : nil
  918      }
  919  }
```

`CoachCore/CoachCore.swift` lines 1187–1192

```swift
 1187  /// A line with a slot still unfilled ("[Name]", "[Day]") never shows (script rule: token fill).
 1188  public enum TokenFill {
 1189      public static func hasOpenSlot(_ line: String) -> Bool {
 1190          line.range(of: #"\[[^\]]{1,30}\]"#, options: .regularExpression) != nil
 1191      }
 1192  }
```

`CoachCore/CoachCore.swift` lines 1045–1072

```swift
 1045  /// The meeting is only "booked" when the prospect's words agree, not when a closing line is shown (N4).
 1046  public enum GoalEvidence {
 1047      static let agree = ["works for me", "that works", "sounds good", "send the invite", "send me the invite", "let's do",
 1048                          "book it", "put me down", "i'm in", "see you then", "that's perfect", "perfect, send"]
 1049      static let times = ["monday", "tuesday", "wednesday", "thursday", "friday", "tomorrow", "next week", " am", " pm", "o'clock"]
 1050  
 1051      public static func mentionsTime(_ text: String) -> Bool {
 1052          let t = " " + text.lowercased() + " "
 1053          // A clock time, not any number ("30 seconds" isn't a meeting time).
 1054          let clock = #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s?(am|pm|a\.m\.|p\.m\.)|\bat \d{1,2}\b"#
 1055          return times.contains(where: { t.contains($0) }) || t.range(of: clock, options: .regularExpression) != nil
 1056      }
 1057  
 1058      static let negative = ["difficult", "can't", "cannot", "won't", "busy", "bad", "doesn't work", "don't", "tough", "booked", "out of"]
 1059      static let positive = ["works", "good", "fine", "great", "perfect", "okay", "ok", "sure", "yes", "yeah"]
 1060  
 1061      /// `afterTimeOffer`: the line they answered offered a time, so a plain "sure" agrees to it.
 1062      public static func confirms(_ prospectSaid: String, afterTimeOffer: Bool = false) -> Bool {
 1063          let t = " " + prospectSaid.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
 1064          let kind = ProspectReply.kind(prospectSaid)
 1065          if kind == .no || kind == .unsure { return false }
 1066          if t.contains(" but ") || t.contains("not ") || negative.contains(where: { t.contains($0) }) { return false }
 1067          if agree.contains(where: { t.contains($0) }) { return true }
 1068          // A day or time alone isn't agreement ("Tuesday is difficult"): it needs a positive word with it.
 1069          if times.contains(where: { t.contains($0) }) { return positive.contains(where: { t.contains(" \($0)") }) }
 1070          return kind == .yes && afterTimeOffer
 1071      }
 1072  }
```

## 12. Getting a real call's exact messages from a trace

The app records every request. The files are on the rep's Mac, one per call:

`~/Library/Logs/ClarityLiveCoach/calls/<date>/<time>-<call>.jsonl`

Each line is a JSON event. These event names give the real, complete messages:
* `context.system`: the full system message (written at call start and whenever it changes). Contains the script. Remove the script's company-specific facts before sharing.
* `claude.request`: `user_message` is the exact user message sent, with `system_hash`, `context` (what the prompt included) and `kind`.
* `claude.settings`: model, effort, max tokens, thinking, timeouts.
* `claude.done`: `output` is the exact raw response (MOVE / STAGE / THINK / SAY / CUE).
* `check.result`, `check.fail`, `check.fixed`, `check.trimmed`, `check.dropped`: every validation outcome.
* `script.match`: every script-answer decision, with the phrase that matched, the detected `intent`, and the reason it fired or was blocked.
* `suggestion.shown`, `.queued`, `.dropped`, `.discarded`, `.superseded`, `.cleared`: what happened to each line and why.
* `question.*`, `objection.*`: the tracker state changes.

To pull one call's messages out of a file on the Mac:

```bash
f=$(ls -t ~/Library/Logs/ClarityLiveCoach/calls/*/*.jsonl | head -1)
grep -E '"(context.system|claude.request|claude.done|script.match|suggestion.shown)"' "$f" | head -60
```

I cannot read those files from this environment (they live on your Mac). If you attach one, I will add the real system and user messages, with names and numbers masked, to this document.

