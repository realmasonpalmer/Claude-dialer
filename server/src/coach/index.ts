import { timingSafeEqual } from "node:crypto";
import type { Server } from "node:http";
import { WebSocketServer } from "ws";
import { ClaudeCoach, type CoachSettings } from "./claude.js";
import { DeepgramStream } from "./deepgram.js";
import { loadSystemPrompt } from "./prompt.js";
import { runSession } from "./session.js";

export interface CoachConfig {
  deepgramApiKey: string;
  accessCode: string;
  settings: CoachSettings;
}

/** Returns null when the coach is not configured, so the dialer can run alone. */
export function loadCoachConfig(): CoachConfig | null {
  const deepgramApiKey = process.env.DEEPGRAM_API_KEY;
  if (!deepgramApiKey) return null;
  const accessCode = process.env.COACH_ACCESS_CODE;
  if (!accessCode || accessCode.length < 12) throw new Error("COACH_ACCESS_CODE must be at least 12 characters");
  if (!process.env.ANTHROPIC_API_KEY) throw new Error("Missing required env var ANTHROPIC_API_KEY");
  const effort = (process.env.CLAUDE_EFFORT ?? "low") as CoachSettings["effort"];
  return {
    deepgramApiKey,
    accessCode,
    settings: { model: process.env.CLAUDE_MODEL ?? "claude-opus-5-5", effort },
  };
}

function codeMatches(given: string, expected: string) {
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Adds the /coach/ws audio socket to an HTTP server. */
export function attachCoach(server: Server, config: CoachConfig) {
  const coach = new ClaudeCoach(config.settings, loadSystemPrompt());
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });

  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.pathname !== "/coach/ws") {
      socket.destroy();
      return;
    }
    if (!codeMatches(url.searchParams.get("code") ?? "", config.accessCode)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      runSession(ws, {
        coach,
        openTranscriber: (events) => new DeepgramStream(config.deepgramApiKey, events),
      });
    });
  });
}
