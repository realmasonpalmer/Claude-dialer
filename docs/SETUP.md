# Setup: first test call

Goal: click a phone number in Salesforce and talk to someone through your headset.

Time: about 1 to 2 hours. You need Salesforce admin access and a Twilio account.

Test in a **sandbox first** if you can. The steps below work in production too.

## 1. Twilio (15 min)

1. Buy one US phone number. This is your caller ID.
2. Make an **API Key** (Account > API keys). Save the SID (`SK...`) and secret.
3. Make a **TwiML App** (Voice > TwiML Apps).
   - Voice URL: `https://YOUR-BACKEND/twilio/voice` (method POST)
   - Save the App SID (`AP...`).
4. Turn on **Voice Geo Permissions** for US and Canada only.

## 2. Backend (20 min)

Any host that runs a Docker container and keeps a server up works. Render,
Fly.io or Railway are all fine. Later phases need WebSockets, so skip
"serverless functions only" hosts.

1. Deploy the `server/` folder (it has a Dockerfile).
2. Set the env vars from `server/.env.example`. Make two long random strings
   for `CLARITY_API_KEY` and `TICKET_SECRET` (for example `openssl rand -hex 32`).
3. Check `https://YOUR-BACKEND/health` returns `{"ok":true}`.
4. Put the same URL in the Twilio TwiML App Voice URL (step 1.3).

## 3. Salesforce (30 min)

1. In `salesforce/force-app/main/default/namedCredentials/ClarityDialer.namedCredential-meta.xml`
   replace `https://REPLACE-WITH-YOUR-BACKEND-HOST` with your backend URL.
2. Deploy:
   ```
   cd salesforce
   sf project deploy start --target-org YOUR_ORG --test-level RunSpecifiedTests --tests ClaritySoftphoneControllerTest
   ```
3. Setup > **Named Credentials** > External Credentials > **Clarity Dialer** >
   Principals > `ClarityDialerPrincipal` > Edit > add Authentication Parameter
   `ApiKey` = your `CLARITY_API_KEY`.
4. Assign the **Clarity Dialer User** permission set to the test user.
   If the callout fails with a principal error, also give that user Read on
   the **User External Credentials** object.
5. Setup > **Call Centers** > Import > `salesforce/callcenter/ClarityDialerCallCenter.xml`.
   - The adapter URL is set to `https://clarityconsultingllc--c.vf.force.com/apex/ClaritySoftphone`.
     If your Visualforce domain is different, open `/apex/ClaritySoftphone`
     once and copy that URL into the call center.
6. In the call center, click **Manage Call Center Users** and add the test user.
   - A user can be in only one call center. Moving someone here takes them
     off Aircall. Use a test user first.
7. App Manager > edit the Lightning app (for example Sales) > **Utility Items** >
   Add **Open CTI Softphone**. Move it to the top so it sits bottom-left.
   Save.

## 4. Test call

1. Log in as the test user. Hard refresh.
2. Open a Lead or Contact that has your own cell number and a State.
3. Click the phone number.
4. Allow the microphone when the browser asks.
5. Answer your cell. Talk. Hang up.
6. Pick what happened. Save. Check the Task on the record.

## Settings

Setup > Custom Metadata Types > **Clarity Dialer Setting** > Default:

| Field | Default | Meaning |
| --- | --- | --- |
| Call Window Start Hour | 8 | No calls before 8 AM their time |
| Call Window End Hour | 20 | No calls starting at or after 8 PM their time |
| Allow Unknown Time Zone | checked | If no State, rep must confirm before calling |
| Blocked Lead Statuses | blank | Comma list of Lead Status values never to call |

## If it does not work

| Problem | Fix |
| --- | --- |
| No phone in the utility bar | User not in the call center, or the utility item is missing |
| Panel is blank | Adapter URL is wrong. Use the real Visualforce URL |
| Clicking a number does nothing | Hard refresh. Check the call center has "Use CTI API" = true |
| "Dialer server error 401" | `ApiKey` in Salesforce does not match `CLARITY_API_KEY` |
| "Microphone blocked" | Allow the mic for the Salesforce site in the browser |
| Call says "not approved" | Ticket expired (2 min) or used. Click the number again |
