# Plan, costs and risks

Written 2026-10-30. Prices change. Check vendor pages before quoting a client.

## What I checked in your Salesforce org

- **Enterprise Edition, production** (`clarityconsultingllc.my.salesforce.com`). Open CTI is included. No extra Salesforce license needed.
- **Aircall is already installed** as a call center. Darren and the "Leadership" login use it.
  A user can be in only one call center. Testing our dialer means moving a test user off Aircall.
- **Shared logins** ("Leadership", "Consultant"). Every person on a shared login shows up as the same Twilio caller.
  Fine for testing. For real use, each rep should have their own login so stats and transfers are per person.
- **Mason is not a Salesforce user.** Transfer to Mason will use a phone number in settings, not a Salesforce user.
- **Your call dashboard formulas only count Aircall calls.** `Call_Connect__c`, `Call_Outcome__c`,
  `Call_Meaningful_Conversation__c` and the rest all start with `IF(ISBLANK(aircall__CallId__c), ...)`.
  Calls from this dialer will show as blank. Fix (needs your OK, it touches live reports):
  change `ISBLANK(aircall__CallId__c)` to `AND(ISBLANK(aircall__CallId__c), ISBLANK(CallObject))` in each,
  and add `CONTAINS(CallDisposition, "No Answer")` next to `"unanswered_call"` in `Call_Outcome__c` and `Call_Connect__c`.
- The dialer writes the fields you already have: `CallDisposition`, `CallDurationInSeconds`, `CallType`,
  `CallObject` (Twilio Call SID), `Conversation_Outcome__c`, `Call_Summary__c`, `Description`.

## Key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| How the widget lives in Salesforce | **Open CTI softphone** (a Visualforce page in the utility bar) | It is the only supported way to catch click-to-dial on phone fields. A plain Lightning Web Component cannot. Aircall works the same way. |
| UI tech inside the widget | Plain JavaScript in a static resource | Twilio's browser SDK and Open CTI both run cleanly there. No Lightning Locker issues. |
| Calls | Twilio Voice JS SDK 2.18.5 in the browser, headset audio | Human talks. No AI voice. |
| Who approves a dial | Salesforce Apex | Checks Do Not Call, suppression list, calling hours, and that the number is on the record. Then gets a one-time ticket. |
| Backend | One small Node + TypeScript server | Mints Twilio tokens, checks tickets, returns call instructions to Twilio. Later: audio stream, transcript, Claude. |
| Secrets | Server only. Salesforce holds the shared key in an External Credential | Nothing secret in the browser. |

## Costs (rough, per rep)

A rep doing 100 dials a day. Say 25 connect for 3 minutes and 75 ring out for 30 seconds. About **115 call minutes a day**.

| Item | Price (verify) | Per day | Per month (21 days) |
| --- | --- | --- | --- |
| Twilio outbound US | ~$0.014/min | ~$1.60 | ~$34 |
| Twilio browser leg | ~$0.004/min | ~$0.45 | ~$10 |
| Twilio number | ~$1.15/month | | ~$1 |
| Media Streams (phase 2) | ~$0.004/min | ~$0.30 (connected only) | ~$6 |
| Transcription, 2 tracks (phase 2) | Deepgram ~$0.0077/min/track | ~$1.15 | ~$24 |
| Claude coaching (phase 3) | see below | ~$0.25 to $3.50 | ~$5 to $75 |
| Hosting | Small always-on server | | ~$7 to $25 |
| **Total** | | | **~$85 to $175 per rep** |

Claude cost depends on the model. Rough guess per connected call: about 20 coaching requests, mostly cached prompt.
Claude Opus 5.5 ($4 in / $20 out per million tokens, $0.20 cached) is about $0.14 per connected call.
Claude Haiku 5.5 ($0.10 / $0.50) is under $0.01. We will measure real numbers in phase 3 and pick the model that is fast enough.

Twilio may also add carrier fees and needs **A2P / SHAKEN-STIR caller ID setup** (register your business with Twilio Trust Hub)
or calls get flagged as spam.

## Transcription choice

Twilio Media Streams can send the rep and the prospect as **two separate audio tracks**. So we know who said what
without paying for speaker detection.

| | Deepgram Nova-3 streaming | AssemblyAI Universal-Streaming |
| --- | --- | --- |
| Price | ~$0.0077/min, billed per second | ~$0.0025/min, billed on open connection time |
| Speed | ~300 ms | ~300 ms |
| Notes | Strong on phone audio | Cheapest |

**Recommendation: start with Deepgram**, keep the code swappable, and test AssemblyAI on the same 20 calls.
The price gap is about $1 per rep per day. Accuracy on 8 kHz phone audio matters more.

## Compliance (not legal advice)

Built in milestone 1:
- Human starts every call. No auto-dialer, no AI voice.
- Do Not Call field blocks the dial. "They asked us not to call again" sets Do Not Call on save.
- Calling hours: 8 AM to 8 PM in the prospect's time zone (from State). States that span two zones must pass both.
  Stricter than the federal 8 AM to 9 PM rule, because some states (for example Florida, Oklahoma, Maryland) are tighter.
- Optional suppression list by Lead Status.
- No recording or transcription yet.

Not built yet. Needs a decision:
- **National Do Not Call Registry scrub.** Our flags only cover people who told *us* no. B2B calls to business lines
  are mostly exempt, but cell phones are not. Use a scrub service or the FTC registry before calling lists.
- **State rules** on Sundays, holidays and call frequency (for example Florida limits 3 calls in 24 hours per topic).
- **Recording and transcription consent.** About a dozen states need all parties to agree (California, Florida,
  Pennsylvania, Washington and others). Phase 2 must play or say a notice and get a yes before audio goes to transcription.
- Data retention: how long to keep transcripts. Default proposal: 90 days, then delete.

Have counsel review before using this on real prospect lists.

## Build order

1. **Phone widget + test call** (this build). Done in code. Needs setup and one live call.
2. **Live transcript.** Twilio Media Streams to the backend, then to Deepgram. Consent check first. Show transcript in the panel.
3. **Claude coaching.** One suggestion and one cue at a time. Fire only after a real prospect statement.
   Cancel stale requests. Keep the last good suggestion on errors. Do not swap text while the rep is reading. Log latency.
4. **AI wrap-up.** Claude drafts summary, disposition and next step. Rep confirms with one tap.
5. **Warm transfer to Mason.** Conference the call, ring Mason, show him a short summary, then the SDR drops off.
6. **Dashboard.** Dials, connects, meaningful conversations, meetings, transfers, coaching latency, cost per qualified conversation.
7. **Tune** with real SDR calls.

## Open questions for you

1. OK to test in production with a test user, or do you have a sandbox?
2. Which host for the backend? (Render is the simplest.)
3. Mason's transfer number and hours.
4. OK to update the Task formulas so dashboard stats count these calls?
