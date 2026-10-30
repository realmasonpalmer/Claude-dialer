import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import WebSocket, { WebSocketServer } from "ws";
import type { CoachRun } from "../src/coach/claude.js";
import { Conversation, type Word } from "../src/coach/conversation.js";
import type { DeepgramEvents } from "../src/coach/deepgram.js";
import { loadSystemPrompt } from "../src/coach/prompt.js";
import { runSession } from "../src/coach/session.js";
import { parseSuggestion, type Suggestion } from "../src/coach/suggestion.js";

function words(speaker: number, text: string, start: number): Word[] {
  return text.split(" ").map((t, i) => ({ text: t, speaker, start: start + i * 0.3, end: start + i * 0.3 + 0.25 }));
}

test("parses streamed suggestion text", () => {
  assert.deepEqual(parseSuggestion("REP: 1\nSAY: That's great. Are they"), {
    rep: 1, say: "That's great. Are they", cue: "", skip: false,
  });
  assert.equal(parseSuggestion("REP: 0\nSKIP").skip, true);
  assert.equal(parseSuggestion("REP: 0\nSAY: Hi\nCUE: Smile.").cue, "Smile.");
});

test("coaches on real prospect statements, not filler or the rep", () => {
  const c = new Conversation();
  c.addFinalWords(words(0, "Hello?", 0));
  assert.ok(c.shouldCoach(), "opening hello gets an opener");
  c.markCoached();
  assert.ok(!c.shouldCoach(), "same words never coached twice");

  c.addFinalWords(words(1, "Hi Jane, this is Sam with Clarity.", 1));
  c.setRep(1, false);
  assert.ok(!c.shouldCoach(), "rep just spoke");

  c.addFinalWords(words(0, "We already have an internal AI team.", 4));
  assert.ok(c.shouldCoach());
  c.markCoached();

  c.addFinalWords(words(1, "Got it.", 8));
  c.addFinalWords(words(0, "Yeah.", 9));
  assert.ok(!c.shouldCoach(), "filler alone does not trigger");
  assert.match(c.transcript(), /Prospect \(speaker 0\): We already/);
});

test("rep tap overrides Claude's guess", () => {
  const c = new Conversation();
  c.setRep(0, true);
  c.setRep(1, false);
  assert.equal(c.repSpeaker, 0);
});

test("system prompt includes the playbook", () => {
  assert.match(loadSystemPrompt(), /Clarity Consulting helps businesses adopt Claude/);
});

test("session streams transcript and a suggestion, cancels stale ones", async () => {
  let events!: DeepgramEvents;
  const audio: Buffer[] = [];
  const runs: { aborted: boolean }[] = [];

  const fakeCoach = {
    suggest(_t: string, _n: string, onUpdate: (s: Suggestion) => void): CoachRun {
      const state = { aborted: false };
      runs.push(state);
      const done = new Promise<any>((resolve) => {
        setTimeout(() => {
          const s = parseSuggestion("REP: 1\nSAY: Are they building tools or driving adoption?\nCUE: Acknowledge, then probe.");
          if (!state.aborted) onUpdate(s);
          resolve({ suggestion: s, firstTokenMs: 5, totalMs: 10, aborted: state.aborted });
        }, 20);
      });
      return { abort: () => { state.aborted = true; }, done };
    },
  };

  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on("connection", (ws) =>
    runSession(ws, {
      coach: fakeCoach,
      openTranscriber: (e) => { events = e; return { send: (b) => audio.push(b), close() {} }; },
      log: () => {},
    }),
  );
  await new Promise<void>((r) => server.listen(0, r));
  const client = new WebSocket(`ws://127.0.0.1:${(server.address() as AddressInfo).port}`);
  const got: any[] = [];
  client.on("message", (d) => got.push(JSON.parse(d.toString())));
  await new Promise((r) => client.once("open", r));

  client.send(Buffer.alloc(1280));
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(audio.length, 1);

  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
  events.onWords(words(0, "Hello?", 0), true, true);
  await wait(40); // Claude's first run names speaker 1 as the rep
  events.onWords(words(1, "Hi, Sam with Clarity.", 1), true, true);
  assert.equal(runs.length, 1, "rep's own line did not trigger");

  events.onWords(words(0, "Is this a sales call?", 3), true, true);
  events.onWords(words(0, "We already have an internal AI team.", 5), true, true);
  await wait(80);
  assert.equal(runs.length, 3);
  assert.equal(runs[1].aborted, true, "stale request cancelled");
  const final = got.filter((m) => m.type === "suggestion" && m.done);
  assert.deepEqual(final.map((m) => m.id), [1, 3]);
  assert.match(final[0].say, /building tools/);
  assert.ok(got.some((m) => m.type === "transcript" && m.rep === 1));

  client.terminate();
  wss.close();
  server.closeAllConnections();
  server.close();
});

test("session reconnects transcription after a drop", async () => {
  const opened: DeepgramEvents[] = [];
  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on("connection", (ws) =>
    runSession(ws, {
      coach: { suggest: () => ({ abort() {}, done: new Promise(() => {}) }) },
      openTranscriber: (e) => { opened.push(e); return { send() {}, close() {} }; },
      log: () => {},
    }),
  );
  await new Promise<void>((r) => server.listen(0, r));
  const client = new WebSocket(`ws://127.0.0.1:${(server.address() as AddressInfo).port}`);
  await new Promise((r) => client.once("open", r));

  opened[0].onClose();
  await new Promise((r) => setTimeout(r, 650));
  assert.equal(opened.length, 2);

  client.terminate();
  wss.close();
  server.closeAllConnections();
  server.close();
});
