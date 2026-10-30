# Clarity Dialer: Claude AI Sales Copilot

Two tools. Use either one.

- **Call Coach** (start here): a web page that listens to your call through one mic
  and shows the next line to say. Works with any phone. Setup: [docs/COACH.md](docs/COACH.md).
- **Dialer**: a phone widget inside Salesforce with click-to-call through Twilio.

Claude coaches the rep in private. Claude never speaks to the prospect.

## Status

| Milestone | State |
| --- | --- |
| 1. Phone widget + click-to-call test call | Built. Needs setup and a live test call. |
| 2. Live transcript (consent first) | Next |
| 3. Claude coaching | After transcript |
| 4. AI summary, disposition, follow-up | Basic manual version is in milestone 1 |
| 5. Warm transfer to Mason | Later |
| 6. Dashboard | Later |

## What is in this repo

```
server/       Node + TypeScript backend: Call Coach (mic -> Deepgram -> Claude) and dialer (Twilio)
server/public The Call Coach web page
server/playbook.md  What the coach knows about Clarity. Edit in plain English.
salesforce/   Salesforce metadata: phone page, Apex, settings, permission set
docs/         Plan, costs, risks and the setup steps
```

## How a call works

1. Rep clicks a phone number on a Lead or Contact.
2. The phone panel opens in the utility bar.
3. Salesforce checks: Do Not Call, suppression list, calling hours, number is on the record.
4. If all good, the backend gives a one-time ticket for that number only.
5. The browser dials through Twilio. The rep talks on their headset.
6. When the call ends, a Task is saved right away. The rep picks what happened and hits Save.

Setup: [docs/SETUP.md](docs/SETUP.md). Plan, costs and risks: [docs/PLAN.md](docs/PLAN.md).

## Run the backend tests

```
cd server && npm install && npm test
```
