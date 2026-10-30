import Anthropic from "@anthropic-ai/sdk";
import { parseSuggestion, type Suggestion } from "./suggestion.js";
import { userPrompt } from "./prompt.js";

export interface CoachSettings {
  model: string;
  effort: "low" | "medium" | "high";
}

export interface CoachResult {
  suggestion: Suggestion;
  firstTokenMs: number | null;
  totalMs: number;
  aborted: boolean;
}

export interface CoachRun {
  abort(): void;
  done: Promise<CoachResult>;
}

// Server-side refusal fallback is supported on Opus and Fable models only.
function supportsFallback(model: string) {
  return model.startsWith("claude-opus") || model.startsWith("claude-fable");
}

export class ClaudeCoach {
  private client = new Anthropic();

  constructor(
    private settings: CoachSettings,
    private systemPrompt: string,
  ) {}

  /** Streams one suggestion. onUpdate fires every time more text arrives. */
  suggest(transcript: string, notes: string, onUpdate: (s: Suggestion) => void): CoachRun {
    const started = Date.now();
    let firstTokenMs: number | null = null;
    let text = "";
    let aborted = false;

    const stream = this.client.beta.messages.stream({
      model: this.settings.model,
      max_tokens: 2000,
      output_config: { effort: this.settings.effort },
      system: [{ type: "text", text: this.systemPrompt, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: userPrompt(transcript, notes) }],
      ...(supportsFallback(this.settings.model)
        ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }
        : {}),
    });

    stream.on("text", (delta) => {
      if (firstTokenMs === null) firstTokenMs = Date.now() - started;
      text += delta;
      onUpdate(parseSuggestion(text));
    });

    const done = stream
      .finalMessage()
      .then((message) => {
        if (message.stop_reason === "refusal") text = "SKIP";
        return { suggestion: parseSuggestion(text), firstTokenMs, totalMs: Date.now() - started, aborted };
      })
      .catch((err: unknown) => {
        if (aborted) {
          return { suggestion: parseSuggestion(text), firstTokenMs, totalMs: Date.now() - started, aborted };
        }
        throw err;
      });

    return {
      abort() {
        aborted = true;
        stream.abort();
      },
      done,
    };
  }
}
