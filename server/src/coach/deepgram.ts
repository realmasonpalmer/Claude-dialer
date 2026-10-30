import WebSocket from "ws";
import type { Word } from "./conversation.js";

// Tuned for speed: tiny endpointing, interim results, speaker labels.
const PARAMS = new URLSearchParams({
  model: "nova-3",
  encoding: "linear16",
  sample_rate: "16000",
  channels: "1",
  interim_results: "true",
  endpointing: "300",
  utterance_end_ms: "1000",
  vad_events: "true",
  diarize: "true",
  smart_format: "true",
});

export interface DeepgramEvents {
  onWords(words: Word[], isFinal: boolean, speechFinal: boolean): void;
  onUtteranceEnd(): void;
  onError(err: Error): void;
  onClose(): void;
}

interface DgWord {
  word: string;
  punctuated_word?: string;
  speaker?: number;
  start: number;
  end: number;
}

export class DeepgramStream {
  private ws: WebSocket;
  private queue: Buffer[] = [];
  private keepAlive: NodeJS.Timeout;
  private lastAudioAt = Date.now();

  constructor(apiKey: string, events: DeepgramEvents) {
    this.ws = new WebSocket(`wss://api.deepgram.com/v1/listen?${PARAMS}`, {
      headers: { Authorization: `Token ${apiKey}` },
    });
    this.ws.on("open", () => {
      for (const chunk of this.queue) this.ws.send(chunk);
      this.queue = [];
    });
    this.ws.on("message", (data) => {
      let msg: any;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (msg.type === "Results") {
        const words: DgWord[] = msg.channel?.alternatives?.[0]?.words ?? [];
        events.onWords(
          words.map((w) => ({ text: w.punctuated_word ?? w.word, speaker: w.speaker ?? 0, start: w.start, end: w.end })),
          Boolean(msg.is_final),
          Boolean(msg.speech_final),
        );
      } else if (msg.type === "UtteranceEnd") {
        events.onUtteranceEnd();
      }
    });
    this.ws.on("error", (err) => events.onError(err));
    this.ws.on("close", () => events.onClose());

    // Deepgram closes idle streams after ~10s. Keep it open while paused.
    this.keepAlive = setInterval(() => {
      if (this.ws.readyState === WebSocket.OPEN && Date.now() - this.lastAudioAt > 5000) {
        this.ws.send(JSON.stringify({ type: "KeepAlive" }));
      }
    }, 5000);
  }

  send(chunk: Buffer) {
    this.lastAudioAt = Date.now();
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(chunk);
    else if (this.ws.readyState === WebSocket.CONNECTING) this.queue.push(chunk);
  }

  close() {
    clearInterval(this.keepAlive);
    if (this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "CloseStream" }));
      setTimeout(() => this.ws.close(), 500);
    } else {
      this.ws.terminate();
    }
  }
}
