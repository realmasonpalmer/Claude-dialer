import Foundation

/// Clarity's cold call backbone: the format and level of detail every written script should match,
/// and how the live coach reads a script (pick order, stage tables, fallbacks).
/// Also ships as its own campaign so it can be called right away.
enum ColdCallBackbone {
    static let campaignID = UUID(uuidString: "5C0FF1CE-BAC0-4B0E-9D1A-C1A217C0B0B1")!

    static var campaign: Campaign {
        var c = Campaign(
            id: campaignID,
            name: "Cold call: AI health check",
            objective: "Book a free 45 minute AI health check with Oliver, our managing partner.",
            pastedScript: text,
            company: "Clarity Consulting. Anthropic partner. Salesforce partner."
        )
        c.persona = "Owners and partners at firms that live on client calls, like tax and accounting firms."
        return c
    }

    static let text = #"""
COLD CALL BACKBONE FOR LIVE RESPONSE TOOL

OUTPUT RULES
Show one line for the SDR to say. Max 25 words.
End the line with a question unless the stage says end the call.
Use only the lines and facts in this file. Fill in the [slots].
Never invent a number, client name, price or offer.
If the prospect asks a question, answer it in one sentence, then ask the next stage question.
If nothing matches, use the fallback for the current stage.
If the SDR and prospect talk at once, show nothing until the prospect stops.
After the SDR asks a question, show nothing for 4 seconds of silence. At 6 seconds show: “Still with me?”

BANNED WORDS AND CLAIMS
Never show a line that says or implies any of these:
The firm was “selected”, “assigned” or “referred”
We are “corresponding with” or “coordinating with” someone
“I left a message” when we did not
Anthropic sent us or asked for the call
“Claude certified” or “certified architects”
“AI never messes up”
A client name
A price, a dollar value or a gift card

TRANSCRIPT NOISE
Treat these as the same word:
Claude: cloud, quad, claw, clod, plot, club
Anthropic: enanthropic, nanthropic, and profit, anthropics
Clarity: clearity, charity
CRM: C R M, serum
Salesforce: sales force

FACTS
Clarity Consulting. Anthropic partner. Salesforce partner.
A tax firm of ten got back about 2,000 hours a year. About 4 hours a week per person.
After every client call, AI fills in the CRM fields.
Works with any CRM, or none.
We build custom connectors so Claude works inside tools a team already uses.
Free 45 minute AI health check with Oliver, our managing partner.

STATE TO TRACK
line_type: screen, tree, gatekeeper, decision_maker, voicemail
stage: S0 to S8
problem_named: yes or no
no_count: 0, 1, 2
slots: name, role, firm, crm, notetaker, email, direct_line, callback_time, meeting_time

PICK ORDER
Check in this order. Use the first match.
Opt out
Second no
Voicemail, phone tree or call screen
Gatekeeper
Prospect asked a direct question
Objection
Stage branch
Stage fallback

GLOBAL TRIGGERS
ID	Sounds like	Say	Then
G1 opt out	“take me off”, “stop calling”, “do not call”	“Done. Sorry to bother you. Have a good day.”	End. Mark do not call.
G2 second no	any no when no_count = 1	“Understood. Thanks for picking up, [Name].”	End.
G3 call screen	“record your name and reason for calling”	“[SDR] with Clarity Consulting, about client call notes.”	Wait.
G4 phone tree	“press 1”, “dial by name”, “extension”	Show: USE NAME DIRECTORY. NO VOICEMAIL ON MENU.	S0
G5 voicemail	“leave a message”, “after the tone”, “not available”	Show next voicemail in order.	End.
G6 wrong person	“not my area”, “I don’t handle that”	“Who owns that? Can I say you sent me?”	Get name and direct_line. S8
G7 left company	“no longer with”, “between jobs”, “my next gig”	“Thanks for telling me. Who took over your role there?”	S8
G8 bad time	“driving”, “in a meeting”, “call me later”	“No problem. Is later today or tomorrow morning better?”	Get callback_time. End.

S1: GATEKEEPER
Enter when line_type = gatekeeper. Never pitch here.
ID	Sounds like	Say	Then
S1 open	“thank you for calling”, “how can I help”	“Hi, it’s [SDR] with Clarity Consulting. Is [Name] in?”	S1
S1 what about	“what is this regarding”, “what’s this about”	“It’s about cutting the time [Name]’s team spends typing up client calls. Is [Name] around?”	S1
S1 expecting	“is he expecting you”	“No, not yet. It will take one minute. Can you try [Name]?”	S1
S1 what company	“who are you with”, “what company”	“Clarity Consulting. We help teams stop typing up client calls. Is [Name] free?”	S1
S1 not in	“in a meeting”, “not available”, “try back”	“No problem. When is a good time to catch [Name]?”	Get callback_time.
S1 direct line	after callback_time	“Is there a direct line I should use?”	Get direct_line. S8
S1 message	“I can take a message”	“Thanks. Say [SDR] from Clarity Consulting called about client call notes. When is [Name] usually at their desk?”	S8
S1 email	“send an email”, “I’ll forward it”	“Happy to. What’s [Name]’s direct email, so it does not get lost?”	Get email. S8
S1 not decider	“he’s not the one”, “group decision”	“Good to know. Who is?”	Get name. S1
S1 tech team	“tech department”, “IT handles that”	“Great. Who runs that team?”	Get name. S1
S1 no	“not interested”, “we’re all set”	“Understood. Thanks for your time.”	End.
S1 transfer	“one moment”, “I’ll put you through”	Show nothing.	S2
S1 fallback	anything else	“When is a good time to catch [Name]?”	S1

S2: OPENER
Enter when line_type = decision_maker.
ID	Sounds like	Say	Then
S2 open	“hello”, “this is [Name]”	“Hi [Name], it’s [SDR] with Clarity Consulting. This is a cold call. Can I take 30 seconds to say why I called?”	S2
S2 yes	“sure”, “go ahead”, “why not”, “make it quick”	Show S3 line.	S3
S2 who	“who is this”, “who?”	“[SDR] with Clarity Consulting. We help firms stop typing up client calls. Can I take 30 seconds?”	S2
S2 busy	“I’m busy”, “no time”	“Got it. Ten seconds, then you decide. Fair?”	S2
S2 early no	“not interested”	“Fair, I haven’t said anything yet. Can I ask one question and then let you go?”	no_count +1. S2
S2 number	“how did you get my number”	“From a business directory. Can I ask one quick question before I let you go?”	S2
S2 fallback	anything else	“Can I take 30 seconds to say why I called?”	S2

S3: REASON
Show one line. Then show the S4 line right away.
ID	When	Say
S3 tax	tax or accounting firm	“We work with tax firms. One team of ten got back about 2,000 hours a year. After every client call, AI fills in their CRM.”
S3 other	any other firm	“We work with teams that live on client calls. One firm of ten got back about 2,000 hours a year. AI fills in their CRM after every call.”

S4: THE QUESTION
ID	Say	Then
S4 ask	“After a client call at [Firm], what happens to the notes?”	S5

S5: DISCOVERY
Set problem_named = yes when the prospect names typing, copying, missed notes, lost deals, time spent or a tool that does not connect.
ID	Sounds like	Say	Then
S5 manual	“we type them”, “I write it up”, “in a notebook”, “we don’t really”	“Who does that typing?”	S5 manual 2
S5 manual 2	names a person or team	“About how long does it take after each call?”	S5 manual 3
S5 manual 3	gives a time	“What slips when someone is too busy to do it?”	problem_named = yes. S6
S5 notetaker	“we have AI for that”, “it takes notes”, “we get a transcript”	“Good, that’s the hard part done. Does it fill in the fields on the client record, or does someone copy that over?”	S5
S5 copies	“someone copies”, “we paste it”, “manually”	“Who does that, and how long does it take?”	problem_named = yes. S6
S5 all good	“it all syncs”, “we’re good”, “in good shape”, “in house”, “yes indeed”	“Nice. What’s the one thing you wish it did that it doesn’t yet?”	S5
S5 wish	names a tool, a gap or a wish	“Tell me more. What would that save you?”	problem_named = yes. S6
S5 nothing	“nothing”, “not really”, “can’t think of anything”	“Fair enough. Can I check back in a few months?”	S8
S5 starting	“just getting started”, “beginning stages”, “looking into it”	“Good place to be. What’s the first thing you want it to take off your team’s plate?”	S5
S5 no crm	“we don’t use a CRM”, “spreadsheets”, “email”	“Got it. Where does client info live today, and who keeps it up to date?”	S5
S5 other crm	“we don’t use Salesforce”, names another CRM	“That’s fine. This works with any CRM. What happens to notes after a call?”	S5
S5 referrals	“word of mouth”, “referrals”	“Good sign. When a referral calls in, where does that info go?”	S5
S5 uses claude	“we use Claude”, “we built our own”, “we have seats”	“Great. What’s the one tool you wish Claude could talk to?”	S5
S5 ai company	“we’re an AI shop”, “we build AI”	“Then you’re ahead of most. Is there anything on the sales side your team still does by hand?”	S5
S5 dont know	“I don’t know”, “not sure”	“No worries. Who on your team would know?”	Get name. S8
S5 fallback	anything else	“Got it. And after that, who updates the client record?”	S5

S6: THE ASK
Enter only when problem_named = yes.
ID	Sounds like	Say	Then
S6 ask	entry	“Sounds worth a look. Oliver, our managing partner, does a free 45 minute AI health check. I have [Day] at [Time] or [Day] at [Time]. Which is better?”	S6
S6 yes	picks a time, “that works”, “Thursday”	Show S7 line.	S7
S6 what is it	“what is that”, “what do you do in it”	“Oliver looks at how your team handles client calls and shows what AI can take off their plate. [Day] or [Day]?”	S6
S6 too long	“that’s a long time”, “45 minutes?”	“We can do 20. If it’s not useful in ten, you hang up. [Day] or [Day]?”	S6
S6 calendar	“let me check”, “not sure of my schedule”	“Sure, I’ll hold. Or I can text you two times right now. Which is easier?”	S6
S6 away	“out of town”, “not this week”	“No problem. Which week are you back? I’ll hold a time now.”	S6
S6 send info	“send me information”, “send me something”	“Happy to. What’s the one part you’d want to see?”	S6 send info 2
S6 send info 2	names a topic	“I’ll send that today. Can I pencil in [Day] so you can ask Oliver about it?”	S6
S6 fallback	anything else	“Would [Day] or [Day] be easier?”	S6

S7: CLOSE
ID	Sounds like	Say	Then
S7 email	entry	“What’s the best email for the invite?”	Get email.
S7 others	email given	“Great. You’ll get the invite in a few minutes. Anyone else who should be on it?”	S7
S7 end	answers	“Thanks, [Name]. Talk [Day].”	End. Show: SEND INVITE WITH AGENDA NOW.
S7 text	“text me”, “I’ll text you my email”	“Works for me. What’s the best number to text?”	S7 end

S8: EXIT WITHOUT A MEETING
ID	Sounds like	Say	Then
S8 note	entry	“Thanks for the time, [Name]. Can I send a short note so you have my info?”	Get email.
S8 end	any reply	“Have a good one.”	End.

OBJECTIONS
Match at any stage after S2.
ID	Sounds like	Say	Then
O1 email	“send me an email”, “email me”	“Happy to. So I send the right thing, what happens to notes after a client call today?”	S5
O2 no	“not interested”, “we’re not in the market”	“Fair. Is that because call notes are not a problem, or just bad timing?”	no_count +1
O2a	“not a problem”	Show S5 all good line.	S5
O2b	“bad timing”	“When is better? I’ll call then.”	Get callback_time. End.
O3 pass	“I’ll pass”, “no thanks”	“Understood. Before I go, what does your team use for call notes today?”	no_count +1. S5
O4 time	“don’t have time for this”	“That’s why I called. This gives time back. Is [Day] or [Day] calmer?”	S6
O5 cost	“how much”, “what does it cost”	“The health check is free. Oliver gives you a real number after he sees how you work. [Day] or [Day]?”	S6
O6 catch	“what’s the catch”, “why is it free”	“No catch. If Oliver finds hours to save, you can hire us or not. [Day] or [Day]?”	S6
O7 tried	“we tried AI”, “it didn’t work”	“That’s common. What went wrong?”	problem_named = yes. S6
O8 vendor	“we have an IT guy”, “we have a vendor”	“Good. We work alongside them. What’s on their list they have not gotten to?”	S5
O9 who	“who are you again”, “what company”	“Clarity Consulting. We’re an Anthropic partner. We set up AI that fills in your CRM after every call.”	Back to last stage question.
O10 why us	“who referred you”, “why are you calling us”	“No one referred me. I call firms that spend a lot of time on client calls. Is that true at [Firm]?”	S4
O11 robot	“is this AI”, “is this a robot”	“No, it’s [SDR], a real person. Can I ask one quick question?”	Back to last stage question.
O12 season	“tax season”, “call after April”	“Makes sense. Would it help to have this fixed before the rush, or should I call back after?”	S6 or callback
O13 partner	“talk to my partner”, “run it by”	“Sure. Should we put them on the invite so you both see it at once?”	S6
O14 what do you do	“just tell me what you do”, “what is this”	“After every client call, AI fills in your CRM. Your team stops typing notes. What happens to notes at [Firm] today?”	S5
O15 crm only	“we don’t need a CRM”, “is this a CRM”	“We’re not selling a CRM. We connect Claude to tools you already use. Which one is hardest to connect?”	S5

VOICEMAIL
Personal voicemail only. Show one per attempt, in order.
ID	Say
VM1	“Hi [Name], [SDR] with Clarity Consulting. We helped a tax firm of ten get back about 2,000 hours a year by ending call note typing. Want to see how? [Number]. Again, [Number].”
VM2	“Hi [Name], [SDR] with Clarity Consulting. Quick question. After a client call, who updates the client record at [Firm]? We took that off one tax firm’s plate. [Number].”
VM3	“Hi [Name], [SDR] with Clarity Consulting. One firm we work with got back about four hours a week per person. I’ll text you the details. [Number].”
VM4	“Hi [Name], [SDR] with Clarity Consulting. Last try from me. If call notes are a problem at [Firm], I can show you the fix in ten minutes. [Number].”

AFTER THE CALL
ID	When	Send
T1	no answer, attempt 1	“Hi [Name], [SDR] with Clarity Consulting. Just tried you. We helped a tax firm of ten get back about 2,000 hours a year by ending call note typing. Worth a 10 minute look?”
T2	no answer, attempt 2	“Hi [Name], [SDR] again. After a client call at [Firm], who updates the client record?”
L1	LinkedIn request	“Hi [Name], I work with firms on cutting the time spent typing client call notes. Would like to connect.”
L2	request accepted	“Thanks for connecting, [Name]. We helped a tax firm of ten get back about 2,000 hours a year. After a client call at [Firm], what happens to the notes?”
L3	they reply	“That’s what we hear a lot. Oliver does a free 45 minute AI health check and shows you where the hours are. Is [Day] or [Day] better?”
L4	no reply in 4 days	“[Name], is typing up client calls a problem at [Firm], or is this not a fit right now?”
"""#
}
