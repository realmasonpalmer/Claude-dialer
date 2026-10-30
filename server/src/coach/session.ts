import type WebSocket from "ws";
import type { CoachRun } from "./claude.js";
import { Conversation, type Word } from "./conversation.js";
import type { DeepgramEvents } from "./deepgram.js";
import type { Suggestion } from "./suggestion.js";

// The two outside services, behind small interfaces so tests can fake them.
export interface Transcriber {
  send(chunk: Buffer): void;
  close(): void;
}
export interface Coach {
  suggest(transcript: string, notes: string, onUpdate: (s: Suggestion) => void): CoachRun;
}
export interface SessionDeps {
  openTranscriber(events: DeepgramEvents): Transcriber;
  coach: Coach;
  log?: (entry: Record<string, unknown>) => void;
}

// A short "Hello?" right after the opener is on screen needs no new line.
const GREETING_MAX_WORDS = 4;

/**
 * One browser tab, many calls. Audio in, suggestions out.
 * Nothing is stored: the transcript lives in memory and is gone on "Next call" or when the tab closes.
 */
export function runSession(browser: WebSocket, deps: SessionDeps) {
  let convo = new Conversation();
  const log = deps.log ?? ((e) => console.log(JSON.stringify(e)));
  let notes = "";
  let interim = "";
  let streamStartedAt = 0; // wall clock when audio began; Deepgram times are relative to it
  let current: CoachRun | null = null;
  let seq = 0;
  let openerReady = false;
  let closed = false;
  let retries = 0;
  let timeOffset = 0; // each new transcriber stream restarts its clock at 0

  const send = (msg: Record<string, unknown>) => {
    if (browser.readyState === browser.OPEN) browser.send(JSON.stringify(msg));
  };
  const pushTranscript = () => send({ type: "transcript", turns: convo.view(), interim, rep: convo.repSpeaker });

  function learnRep(speaker: number | null) {
    if (speaker === null || convo.turns.length === 0 || speaker === convo.repSpeaker) return;
    const before = convo.repSpeaker;
    convo.setRep(speaker, false);
    if (before !== convo.repSpeaker) pushTranscript();
  }

  /** Asks Claude for the next line. Any newer request cancels this one. */
  function generate(kind: "opener" | "reply") {
    current?.abort();
    const id = ++seq;
    const askedAt = Date.now();
    const speechEndedAt = kind === "reply" ? streamStartedAt + convo.lastWordEnd() * 1000 : askedAt;
    const forConvo = convo;
    let shownFirstWords = false;

    const run = deps.coach.suggest(convo.transcript(), notes, (s) => {
      if (forConvo !== convo) return;
      learnRep(s.rep); // REP is Claude's first line, so we learn who the rep is right away
      if (id !== seq) return;
      if (s.say && !shownFirstWords) {
        shownFirstWords = true;
        if (kind === "reply") send({ type: "latency", id, speechEndToFirstWordMs: Date.now() - speechEndedAt });
      }
      send({ type: "suggestion", id, kind, say: s.say, cue: s.cue, stage: s.stage, skip: s.skip, done: false });
    });
    current = run;

    run.done
      .then((result) => {
        if (forConvo !== convo) return;
        learnRep(result.suggestion.rep);
        if (result.aborted || id !== seq) return;
        const { say, cue, stage, skip } = result.suggestion;
        if (kind === "opener" && say) openerReady = true;
        send({ type: "suggestion", id, kind, say, cue, stage, skip, done: true });
        log({
          event: "coach",
          kind,
          firstTokenMs: result.firstTokenMs,
          totalMs: result.totalMs,
          speechEndToDoneMs: Date.now() - speechEndedAt,
          skip,
        });
      })
      .catch((err: Error) => {
        // Keep the last good suggestion on screen; just flag the hiccup.
        log({ event: "coach_error", message: err.message });
        send({ type: "status", level: "warn", message: "Coach hiccup. Last tip kept." });
      })
      .finally(() => {
        if (current === run) current = null;
      });
  }

  function maybeCoach() {
    if (!convo.shouldCoach()) return;
    const isGreeting =
      openerReady && convo.turns.length === 1 && convo.newProspectWords().length <= GREETING_MAX_WORDS;
    convo.markCoached();
    if (isGreeting) return; // the opener on screen already answers "Hello?"
    generate("reply");
  }

  /** Clears the call but keeps the mic and transcription running. */
  function nextCall() {
    current?.abort();
    current = null;
    const previous = convo;
    convo = new Conversation();
    if (previous.repSpeaker !== null) convo.setRep(previous.repSpeaker, previous.repLocked); // same mic stream, same speaker ids
    convo.skipThrough(previous.lastWordEnd());
    interim = "";
    openerReady = false;
    send({ type: "reset" });
    pushTranscript();
    generate("opener");
  }

  function openTranscriber(): Transcriber {
    let failed = false;
    return deps.openTranscriber({
      onWords(raw: Word[], isFinal: boolean, speechFinal: boolean) {
        retries = 0;
        const words = raw.map((w) => ({ ...w, start: w.start + timeOffset, end: w.end + timeOffset }));
        if (isFinal) {
          convo.addFinalWords(words);
          interim = "";
        } else {
          interim = words.map((w) => w.text).join(" ");
        }
        pushTranscript();
        if (speechFinal) maybeCoach();
      },
      onUtteranceEnd: maybeCoach,
      onError(err) {
        failed = true;
        log({ event: "transcriber_error", message: err.message });
      },
      onClose() {
        if (closed) return;
        // Dropped mid-call: reconnect and keep the transcript and last tip.
        if (retries >= 3) {
          send({ type: "status", level: "error", message: "Transcription lost. Press Stop, then Start." });
          return;
        }
        retries++;
        send({ type: "status", level: "warn", message: failed ? "Reconnecting transcription..." : "Reconnecting..." });
        setTimeout(() => {
          if (closed) return;
          if (streamStartedAt) timeOffset = (Date.now() - streamStartedAt) / 1000;
          transcriber = openTranscriber();
          send({ type: "status", level: "info", message: "Listening." });
        }, 500 * retries);
      },
    });
  }
  let transcriber = openTranscriber();

  browser.on("message", (data, isBinary) => {
    if (isBinary) {
      if (!streamStartedAt) streamStartedAt = Date.now();
      transcriber.send(data as Buffer);
      return;
    }
    let msg: any;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (msg.type === "notes" && typeof msg.notes === "string") {
      notes = msg.notes.slice(0, 2000);
      if (convo.turns.length === 0) generate("opener"); // fresh opener for the new prospect
    }
    if (msg.type === "nextCall") {
      if (typeof msg.notes === "string") notes = msg.notes.slice(0, 2000);
      nextCall();
    }
    if (msg.type === "setRep" && Number.isInteger(msg.speaker)) {
      convo.setRep(msg.speaker, true);
      pushTranscript();
    }
  });

  browser.on("close", () => {
    closed = true;
    current?.abort();
    transcriber.close();
  });

  send({ type: "status", level: "info", message: "Listening." });
}
