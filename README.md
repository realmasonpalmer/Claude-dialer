# Clarity Dialer: Claude AI Sales Copilot

A phone widget inside Salesforce. A rep clicks a phone number, talks to the
prospect through their headset, and Claude coaches them in private. Claude
never speaks to the prospect.

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
server/       Small Node + TypeScript backend (Twilio tokens, call approval, TwiML)
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
