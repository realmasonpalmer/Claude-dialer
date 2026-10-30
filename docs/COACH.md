# Call Coach

A web page that listens to your call through one mic and shows you what to say next.
It works with any phone: Aircall, Zoom, your cell on speaker.

## How to use it

1. Put the call on **speaker** so the mic hears both of you. (A headset will not work. The mic can't hear the other person.)
2. Open the coach page. Enter the access code. Pick your mic.
3. Optional: type who you are calling.
4. Click **Start listening**.
5. Tell the prospect the call is transcribed and get a yes.
6. Read the big line. Say it in your own words.
7. If the transcript labels you wrong, tap one of your own lines. The app fixes it.

## Mic tips

- Use a USB conference mic or speakerphone, like a Jabra Speak or Anker PowerConf. They are built to hear a whole room.
- Put the mic between you and the speaker.
- Turn the call volume up so the other person is about as loud as you.
- The page turns off the browser's echo cancellation on purpose. If it were on, it would erase the prospect's voice.

## What happens to the audio

- Audio goes from your browser to our server, then to Deepgram for live words.
- The words go to Claude for the next line.
- Nothing is saved. The transcript lives in memory and is gone when you close the tab.
- Server logs keep only timing numbers, never the words.

## Speed

The small number at the top is the time from when they stop talking to when the first words of a tip show up.

Where the time goes:
1. Deepgram waits 0.3 seconds of silence to decide they finished.
2. Claude writes the line, and the words show up as they arrive.

Ways to make it faster:
- Set `CLAUDE_MODEL=claude-haiku-5-5`. Fastest. Try it and compare tips.
- Keep `CLAUDE_EFFORT=low`.
- Host the server in a US East region, close to Deepgram and Anthropic.

## Set it up (about 20 minutes)

1. Get a [Deepgram](https://console.deepgram.com) API key and an [Anthropic](https://console.anthropic.com) API key.
2. Deploy the `server/` folder to a host with HTTPS (Render, Fly.io or Railway). The mic only works on HTTPS.
3. Set these env vars:
   - `DEEPGRAM_API_KEY`
   - `ANTHROPIC_API_KEY`
   - `COACH_ACCESS_CODE` (any long password the team will type)
   - `CLAUDE_MODEL` (optional)
   - `CLAUDE_EFFORT` (optional)
4. Open `https://YOUR-HOST/coach/`.

You do not need Twilio or any Salesforce setup for the coach.

## Change what the coach knows

Edit `server/playbook.md` in plain English: offer, who you call, objections, tone. Redeploy.

## Cost (rough)

For one rep with about 75 talk minutes a day:
- Deepgram: about $0.0077 a minute, so about $0.60 a day.
- Claude: depends on the model. We'll measure it on real calls.
- Hosting: about $7 to $25 a month.
