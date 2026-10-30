# Clarity Live Coach

A **Mac app** that sits next to Aircall and Salesforce and coaches a cold caller live.
It is **not** a dialer, a phone system, a Salesforce plugin, or an AI that talks on calls.

- **Calls happen in Aircall** (the Aircall panel in Salesforce, or the Aircall desktop app).
- **Leads live in Salesforce.** The app reads them; it never changes Salesforce.
- **Claude coaches the rep privately.** It never speaks to the prospect.

The whole app is in [`mac/`](mac/) (Swift + SwiftUI, macOS 14.4+).
Start a new chat by reading [`HANDOFF.md`](HANDOFF.md).

## What the app does

1. **Hears both sides of the call.** Your mic = you. The call audio from Chrome or the Aircall
   desktop app = the prospect. Live transcript with Deepgram.
2. **Shows one line to say next** (big), with a short tip. Lines stay until you've said them.
   Stage bar: Opener > Discovery > Value > Close.
3. **Works your list.** "Call [name]" opens the next lead and dials it through Aircall.
   **Double dial:** no answer on the 1st try shows "Redial [name]"; after the 2nd try,
   "Call [next person]". End call button; calls also end when Aircall says so.
4. **Catches voicemails and call screeners** instantly. Voicemail script is written ahead for each
   lead (leave it on the 2nd try). Screener line: "This is [you] calling for [them]."
5. **Follow-ups after a voicemail:** one-click text through Aircall, and LinkedIn opens on
   their profile with the connection note copied.
6. **Books meetings on Oliver's Calendly:** offers two real open times, new ones if declined.
7. **Campaigns:** paste a script, set the goal; Claude sorts it into sections.
8. **Openers:** 5 research-backed openers, rotated by results, with a scoreboard.
9. **Script Lab:** every call is scored; Claude suggests script edits with the numbers behind them.

Two ways it finds the lead you're calling:
- **Chrome version (works today):** reads the Salesforce tab in Chrome, learns your list
  (split view or table view), and clicks the phone number so Aircall dials.
- **Salesforce-list version (optional, needs setup):** connect Salesforce once and pick a list
  view inside the app; calls go through the Aircall desktop app.

## Install and update

- **First time:** download this branch as a ZIP, open Terminal in the `mac` folder, run
  `bash scripts/install.sh`. It builds the app, puts it in Applications, and opens it.
- **After that:** click the blue **Update** button in the app (shows between calls when
  there's a new version). No Terminal.
- Opening the app: Applications, Spotlight ("Clarity"), or the Dock. Never Terminal.

## Out of scope (removed)

Earlier ideas that are **no longer part of this project** and were deleted from the repo:
a Salesforce phone widget (Open CTI + Twilio) meant to replace Aircall, a Twilio dialer
server, and a web-page coach. Don't bring them back unless asked.
