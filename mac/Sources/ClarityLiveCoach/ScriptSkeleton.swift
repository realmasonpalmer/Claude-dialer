import Foundation

/// The bones every generated cold call script is built on: section titles, table layouts, how the
/// stages flow, and the rules that are the same across Clarity. No script lines: those are written
/// fresh for each call segment. The only thing every segment shares is the ask: a free 45 minute
/// CRM or AI health check with Oliver.
enum ScriptSkeleton {
    static let text = #"""
COLD CALL BACKBONE FOR LIVE RESPONSE TOOL
Call segment: [segment name]

HOW THE TOOL RESPONDS
(Copy these rules into the script as written.)
Show one line for the SDR to say. Max 25 words. Voicemails are the only exception.
End the line with a question unless the stage says to end the call.
Use only the lines and facts in this file. Fill in the [slots].
Pick the line by meaning, not exact words. The "Sounds like" phrases are examples.
Save every name, number, tool and time the prospect says, at any stage.
Never ask for something the prospect already said.
If the prospect says two things at once, save both. Reply to the one highest in the pick order.
Do math only with numbers the prospect said. If a number is missing, skip the math.
If the prospect is talking, show nothing until they stop.
If the prospect cuts in, drop the current line and respond to what they said.
When a question is on screen, load the three most likely replies so the next line shows fast.
After the SDR asks a question, show nothing for 4 seconds of silence. At 6 seconds, show: "Still with me?"
Ask no more than 3 discovery questions before S6.
If the prospect gives two short answers in a row, skip S7.

HOW THE SDR SOUNDS
(Copy as written. Add one or two lines about how this segment talks.)
Calm and plain. Like a peer, not a fan.
Use the prospect's own words back to them.
Say their first name at the open and the close only.
No filler: "awesome", "super excited", "beautiful day", "my friend", "brother", "to be honest".
No apology for calling. No small talk about pets, hobbies or LinkedIn.

NEVER SAY
(Copy as written. Add anything this segment would find off-putting or risky.)
The firm was "selected", "assigned" or "referred"
We are "corresponding with" or "coordinating with" someone
"I left a message" when we did not
Anthropic sent us or asked for the call
"Claude certified" or "certified architects"
"AI never messes up"
"Roadmap", "transformation", "maturity", "enablement" or "digital"
Any industry stat or survey number
A client name
A price, a dollar value or a gift card
That a tool or system works with ours, unless it is in FACTS

TRANSCRIPT NOISE
Treat these as the same word:
(Copy these. Add the tools, terms and names this segment uses that speech-to-text could mishear.)
Claude: cloud, quad, claw, clod, plot, club
Anthropic: enanthropic, nanthropic, and profit, anthropics
Clarity: clearity, charity
CRM: C R M, serum
Salesforce: sales force
ChatGPT: chat GPT, chat, GPT

FACTS
(These are the only facts. Copy them. Add nothing that isn't true for every Clarity client.)
Clarity Consulting. Anthropic partner. Salesforce partner. Based in Portland, Oregon.
Oliver, our managing partner, has done this kind of work for over a decade.
After every client call, AI can fill in the CRM fields.
Works with any CRM, or none.
We build custom connectors so Claude works inside tools a team already uses.
Free 45 minute [CRM or AI] health check with Oliver.
In the health check, Oliver looks at where the hours go, who owns the work and what's in the way.
They leave with a short to-do list: the top 3 things to fix first.

STATE TO TRACK
line_type: screen, tree, gatekeeper, decision_maker, voicemail
track: (2 to 4 tracks from the S4 question, named for this segment)
stage: S0 to S11
problem_named: yes or no
confirmed: yes or no
no_count: 0, 1 or 2
short_answers: count of replies under 5 words in a row
slots: name, role, firm, (the tools, numbers and details this segment's discovery collects), email, direct_line, callback_time, meeting_time
(Define any math slot, like total_hours_week = hours per person × people.)

PICK ORDER
Check in this order. Use the first match.
Opt out or angry
Second no
Voicemail, phone tree or call screen
Gatekeeper
Buying signal
Direct question
Objection
Stage branch
Stage fallback

GLOBAL TRIGGERS
ID	Sounds like	Say	Then
(Rows: G1 opt out (end, mark do not call), G2 angry (end), G3 second no (end), G4 call screen (one line with [SDR], Clarity Consulting and the reason, then wait), G5 phone tree (Show: USE NAME DIRECTORY. NO VOICEMAIL ON MENU., S0), G6 voicemail (show the next voicemail in order, end), G7 wrong person (get name and direct_line, S10), G8 left company (S10), G9 bad time (offer two callback times, get callback_time, end), G10 buying signal (straight to the ask, confirmed = yes, S8), G11 link (get email, S9). Write every Say line for this segment.)

S1: GATEKEEPER
Never pitch here. Never ask about their systems.
ID	Sounds like	Say	Then
(Rows: open, what about, expecting, company, not in, direct line, message, email, not decider, tech team, no, transfer (Show nothing, S2), fallback. The one-line reason must matter to this segment.)

S2: OPENER
ID	Sounds like	Say	Then
(Rows: confirm, open, yes (Show the S3 line, S3), who, busy, early no (no_count +1), number, fallback. Honest, permission-based opener.)

S3: REASON
Show one line. Then show the S4 line right away.
ID	When	Say
(One or more lines: a problem people in this segment really have, in their words, framed as what peers deal with. Not the product. Split by sub-type if the segment has them.)

S4: THE QUESTION
ID	Say	Then
(One question that sorts the prospect into the tracks in STATE TO TRACK. S5.)

S5: DISCOVERY
Set problem_named = yes when (the signals that mean this segment has a real problem).
(One table per track, then "Any track" rows for common answers, tools, "we're good", "nothing", "don't know" and a fallback.)
ID	Sounds like	Say	Then

S6: PLAY IT BACK
Enter when problem_named = yes. Use their words.
ID	When	Say	Then
(Rows: math (only with numbers they said), no math, yes (Show the S7 line; if short_answers is 2 or more, show the S8 line; confirmed = yes), fix, small.)

S7: MAKE IT MATTER
Skip if short_answers is 2 or more.
ID	Sounds like	Say	Then
(Rows: ask (what the fix would mean to them), answer (Show the S8 line, S8).)

S8: THE ASK
Enter only when confirmed = yes. The ask is always the free 45 minute [CRM or AI] health check with Oliver, our managing partner, with two specific times: [Day] at [Time] or [Day] at [Time].
ID	Sounds like	Say	Then
(Rows: ask, yes, what is it, too long, calendar, away, send info, send 2, fallback.)

S9: CLOSE
ID	Sounds like	Say	Then
(Rows: email, others, end (End. Show: SEND INVITE WITH AGENDA NOW.), text.)

S10: EXIT WITHOUT A MEETING
ID	Sounds like	Say	Then
(Rows: who, note, end (End. S11).)

S11: AFTER THE CALL
Show: LOG THE OUTCOME. (Name what to save for this segment.)
Pick one outcome:
BOOKED
CALLBACK SET
REFERRED TO [name]
SEND NOTE
NOT NOW
DO NOT CALL
WRONG NUMBER
NO ANSWER: leave the next voicemail, send the next text, send the LinkedIn request

DIRECT QUESTIONS
Answer, then go back to the last stage question unless "Then" says otherwise.
ID	Sounds like	Say	Then
(Rows: what do you do, are you selling, who are you, who have you worked with (never name clients), where are you based, how long, which AI, does it work with [tool], how long to set up, proof, why us, is this AI. Add the questions this segment asks.)

OBJECTIONS
Match at any stage after S2.
ID	Sounds like	Say	Then
(15 to 20 objections this segment really uses. Each: a few words of agreement, then one curious question. Include not interested (no_count +1, with two branches), send an email, cost (the health check is free), what's the catch, we tried it, we do it in house, we have a vendor, security or privacy, not urgent, busy season, talk to my partner, group decision, too small, no budget.)

VOICEMAIL
Personal voicemail only. Show one per attempt, in order. Under 20 seconds.
ID	Say
(VM1 to VM4. Each a new angle. VM4 is the last try.)

TEXTS
ID	When	Send
(T1 no answer, attempt 1. T2 no answer, attempt 2.)

LINKEDIN
ID	When	Send
(L1 connection request, under 200 characters. L2 request accepted. L3 they reply (the health check, two times). L4 no reply in 4 days.)

TEST SLOTS
Run A for 100 dials, then B for 100 dials. Change one slot at a time. Keep the one that books more meetings.
Slot	A	B
(Opener, Question, Ask: two real options each.)
"""#
}
