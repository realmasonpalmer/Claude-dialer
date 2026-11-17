import Foundation

/// The bones every generated cold call script is built on: section titles, table layouts, how the
/// stages flow, and the rules that are the same across Clarity. No script lines: those are written
/// fresh for each call segment. The only thing every segment shares is the ask: a free 45 minute
/// CRM or AI health check with Oliver.
enum ScriptSkeleton {
    static let text = #"""
COLD CALL BACKBONE v3
Call segment: [segment name]

PLAYBOOK
(Fill in for this segment. One playbook = one avatar + one offer.)
avatar_name: (who they are, like "Tax firm owners")
avatar_titles: (3 to 6 real titles)
avatar_language: (8 to 15 words and phrases they really use about their work)
offer_name: AI and customer records health check
offer_length: 45 minutes
host_name: Oliver
host_title: our managing partner
host_years: over a decade
incentive: (lunch for the team, or "none")
incentive_caveat: If they can't accept gifts, drop the lunch and keep the meeting.
problem_lines: (one short problem line per title type, in their words)

1. JOB
Goal: a 45 minute [offer_name] with the decider, on the calendar, with every decider invited.
Best outcome: meeting booked with the decider and other deciders joining.
Second best: callback time set with the decider, or a warm handoff to the right person.

2. OUTPUT CONTRACT
(Copy as written.)
Reply as JSON, "say" first: {"say": "...", "stage": "STAGE", "save": {"slot": "value"}, "flags": []}
Flags: end_call, do_not_call, send_invite, send_email, book_callback, use_directory, needs_human.
One line, 25 words at most. Voicemails are the only exception.
End with a question unless flags has end_call. One question only.

3. INPUTS
(Copy as written.)
Each turn the coach gets: PROSPECT (name, title, company, notes), CALENDAR (Slot A to Slot D, real open
times in the prospect's time zone), STATE (saved slots and counters), EVENT, and the full TRANSCRIPT.

4. PICK ORDER
(Copy as written.) Check in this order. Use the first match.
Opt out or angry
Second no
Voicemail, phone tree or call screen
Gatekeeper
Meeting yes (wants a time, the calendar or the invite)
Info request (send me something: NOT a meeting yes)
Direct question
Objection
Stage row
Stage default

5. RULES
(Copy as written. Add up to 3 for this segment.)
Pick the row by meaning. "Sounds like" phrases are examples.
Save every name, number, tool and time the prospect says, at any stage.
Never ask for something the prospect already said.
Two things at once: save both, answer the one higher in the pick order.
Math only with numbers the prospect said. Missing a number: skip the math.
At most 3 pain questions before PLAYBACK.
Two short answers in a row: skip BRIDGE.
Times come only from CALENDAR as [Slot A] and [Slot B]. Never make up a day or time.
Push through once on a no. On the second no, end politely.
Opt out: say the G1 line, set do_not_call, end. It is written in Salesforce for real.
"Send me info" is not a meeting. Send the email, then ask once for a time.

6. VOICE
(Copy as written. Add 1 or 2 lines for how this segment talks.)
Calm and plain. Like a peer, not a fan.
Outcome first, then the problem, then the fix. Technology last.
Use their words back to them.
Say their first name at the open and the close only.

7. NEVER SAY
(Copy as written. Add anything this segment would find off-putting.)
Any all-caps abbreviation except AI. Say "customer records" or "customer system", not the short form.
Filler: awesome, super excited, beautiful day, my friend, brother, to be honest
selected, assigned, referred, certified, replace, never messes up
"I left a message" unless one was left
Anthropic sent us or asked for the call
roadmap, transformation, maturity, enablement, digital
Any price, dollar amount, percent or survey number
A client name
That a tool works with ours, unless it is in FACTS
Em dashes

8. FACTS
(The only facts. Copy as written. Add only what is true for every Clarity client.)
Clarity Consulting. Anthropic partner. Salesforce partner. Based in Portland, Oregon.
[host_name], [host_title], has done this kind of work for [host_years].
After every client call, AI can fill in the customer record fields.
Works with any customer system, or none.
We build custom connectors so Claude works inside tools a team already uses.
The [offer_name] is free and takes [offer_length].
In it, [host_name] looks at where the hours go, who owns the work and what's in the way.
They leave with the top 3 things to fix first.
Unknown question: "Good question. Oliver can answer that on the call. Want to grab a time?"

9. STATE
(Copy as written. Name the tracks and slots for this segment.)
line_type: screen, tree, gatekeeper, decider, voicemail
track: (2 to 4 tracks from the PROBLEM question, named for this segment)
Counters kept by the app: short_answers, voicemail_count, pain_questions, total_hours_week
Counters kept by the coach: no_count (0, 1, 2), problem_named (yes, no), confirmed (yes, no), track
Slots: name, role, company, (the tools, numbers and details this segment's PAIN rows collect), hours_week,
people, other_deciders, email, direct_line, callback_time, meeting_slot, message_left

10. GLOBALS
ID | Sounds like | Say | Then
(Write every row for this segment.
G1 opt out: honest, one line, flags do_not_call + end_call.
G2 angry: one calm line, end_call.
G3 second no: polite exit, end_call.
G4 call screen: one line with [SDR], Clarity Consulting and the reason, then wait.
G5 phone tree: Say "Use the name directory. No voicemail on menus.", flags use_directory.
G6 voicemail: the next voicemail by voicemail_count, end_call.
G7 wrong person: get the right name and direct_line, HANDOFF.
G8 left the company: ask who took over, HANDOFF.
G9 bad time: offer [Slot A] or [Slot B] for a callback, save callback_time, flags book_callback.
G10 meeting yes: straight to ASK with [Slot A] or [Slot B], confirmed = yes.
G11 info request: "Happy to. What's the best email?", flags send_email, then one ask for a time.)

11. STAGES
For every stage: a short line on when it starts, then a table. Mark exactly one row per stage as
the default with "(default)" after its ID. That's the line the app shows when nothing else fits.
ID | Sounds like | When | Say | Then

GATE
Never pitch. Never ask about their systems.
(Rows: open, what's it about, are they expecting you, not in, direct line, take a message, email, not the
decider, transfer (Say "Show nothing", next OPEN), default.)

OPEN
(Rows: confirm it's them, permission-based open, yes (next REASON), who is this, busy (G9), early no
(no_count +1), default.)

REASON
One line: a problem people like them have, in their words, framed as what peers deal with. Not the product.
(1 to 3 rows, split by title type using problem_lines. Then next PROBLEM right away.)

PROBLEM
One question that sorts them into the tracks in STATE. (Next PAIN.)

PAIN
One short question at a time, per track. Count pain_questions. Set problem_named = yes when (the signals
that mean this segment has a real problem). Collect hours_week and people when you can.
(A small table per track, plus "any track" rows: we're good, nothing, don't know, a tool name, default.)

PLAYBACK
Enter when problem_named = yes. Use their words.
(Rows: math (only with numbers they said: [people] people at [hours_week] hours is [total_hours_week]
hours a week), no math, yes (confirmed = yes; next BRIDGE, or ASK if short_answers is 2 or more), fix it, small.)

BRIDGE
Skip if short_answers is 2 or more.
(Rows: ask what fixing it would mean to them, answer (next ASK).)

ASK
Only when confirmed = yes. Always the free [offer_length] [offer_name] with [host_name], [host_title],
with two real times: [Slot A] or [Slot B].
(Rows: ask, yes (next JOIN), what is it, too long, neither time ([Slot C] or [Slot D]), send info (G11),
default.)

JOIN
Who else decides? (Rows: ask who else should join, names given (save other_deciders, next LOCK), just me
(next LOCK).)

LOCK
Confirm the time and email, flags send_invite. (Rows: email, confirm time, invite sent (end_call),
invite failed (one line: we'll email it, end_call).)

HANDOFF
Handed to someone else. (Rows: who, direct line, warm intro line for the new person, end.)

12. OBJECTIONS
Match at any stage after OPEN. A few words of agreement, then one curious question.
ID | Sounds like | Say | Then
(15 to 20 this segment really uses. Include: not interested (no_count +1, two branches), send an email
(G11), cost (it's free), what's the catch, we tried AI, we do it in house, we have a partner, security,
not urgent, busy season, talk to my partner, group decision, too small, no budget, can't accept gifts
(incentive_caveat).)

13. QUESTIONS
Answer, then back to the last stage question.
ID | Sounds like | Say | Then
(what do you do, are you selling, who are you, who have you worked with (never name clients), where are
you based, how long, which AI, does it work with [tool], how long to set up, why us, is this AI, plus
this segment's own. Anything not in FACTS: the unknown-question line.)

14. VOICEMAILS
Personal voicemail only. One per attempt, in order by voicemail_count. Under 20 seconds.
ID | Say
(VM1 to VM3. Each a new angle. VM3 is the last try.)

TEXTS
ID | When | Send
(T1 after no answer on try 1. T2 after try 2.)

LINKEDIN
ID | When | Send
(L1 connection note under 200 characters. L2 accepted. L3 they reply (two real times). L4 no reply in 4 days.)

15. NOISE MAP
Heard word -> real word. (Copy these. Add this segment's tools and terms speech-to-text could mishear.)
cloud, quad, claw, clod, clyde -> Claude
enanthropic, and profit -> Anthropic
clearity, charity -> Clarity
serum, C R M -> customer system
sales force -> Salesforce
olivier, oliva -> Oliver

16. FAST PATH PHRASES
(Copy and add. The app matches these in code, before Claude.)
opt_out: take me off your list, don't call me again, remove me, stop calling, do not call
voicemail: leave a message, after the tone, after the beep, not available, record your message
phone_tree: press 1, for sales press, dial by name, directory, if you know your party's extension
"""#
}
