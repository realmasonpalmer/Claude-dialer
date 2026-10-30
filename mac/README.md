# Clarity Live Coach (Mac)

A floating Mac window that hears both sides of an Aircall call in Chrome and coaches the rep.

What it does today:
1. **Audio check** (first run): proves it hears you and the prospect as two separate streams.
2. **Connect** (once): paste a Deepgram key and an Anthropic key. Stored in the Keychain.
3. **Coach**: dial from Salesforce. When the call connects it starts listening by itself,
   shows live text for both sides, and shows one line to say plus a short tip. When the call
   ends it clears and gets the next opener ready.

Not built yet: the campaign editor (one built-in Clarity campaign for now).

## Needs

- macOS 14.4 or newer (Apple menu > About This Mac)
- Xcode Command Line Tools: run `xcode-select --install` in Terminal (free, about 10 minutes)
- Aircall working in Chrome inside Salesforce
- A headset is best. Speakers work, but your mic will also pick up the prospect.

## Install or update

From the `mac` folder:

```
bash scripts/install.sh
```

It builds the app, puts it in Applications (replacing any old copy) and opens it.

## Run the audio check

1. Open the app. Click **Allow** for the microphone.
2. Call a teammate (or your own cell) from Aircall in Salesforce. Tell them you're testing.
3. In the app, check that **Call detected in Chrome** turns green.
4. Click **Start**. macOS asks to allow **System Audio Recording**. Click Allow.
   If you miss it: System Settings > Privacy & Security > Screen & System Audio Recording >
   "System Audio Recording Only" > turn on Clarity Live Coach. Then click Stop and Start.
5. Talk. The **You** bar should move. Have them talk. The **Prospect** bar should move.
6. Check **Talking now** switches between You and Prospect.
7. Click **Record test**, talk back and forth for 20 seconds, click **Stop test recording**.
8. Click **Show recordings**. Play `you.wav` and `prospect.wav`.

**Pass** = `you.wav` has your voice, `prospect.wav` has theirs, and **Talking now** follows along.
Then click **Delete recordings**.

Send back: pass or fail, your macOS version, your headset model, and any red error text.

## If it fails

| What you see | Try |
| --- | --- |
| "Chrome isn't using audio yet" | Start the Aircall call first, then press Start |
| Prospect bar never moves | Allow System Audio Recording (step 4), then Stop and Start |
| Prospect bar never moves, permission is on | The call audio may come from the Aircall desktop app, not Chrome. Pick it in "Hear the call from" |
| You bar never moves | Allow the mic in System Settings > Privacy & Security > Microphone |
| Asked for permission again after a rebuild | Normal for unsigned test builds |
