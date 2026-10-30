// Turns Deepgram's diarized words into speaker turns and decides when the
// rep needs a new line. Pure logic, no network, so it is easy to test.

export interface Word {
  text: string;
  speaker: number;
  start: number; // seconds from stream start
  end: number;
}

export interface Turn {
  speaker: number;
  words: Word[];
}

// Short backchannel noises that never need a new suggestion on their own.
const FILLER = new Set([
  "yeah", "yep", "yes", "ok", "okay", "uh", "um", "uh-huh", "mhm", "mm-hmm", "hmm",
  "right", "sure", "got", "it", "cool", "nice", "great",
]);

function clean(word: string): string {
  return word.toLowerCase().replace(/[^a-z'-]/g, "");
}

export class Conversation {
  turns: Turn[] = [];
  repSpeaker: number | null = null;
  repLocked = false; // true once the rep taps "that's me"
  private coachedThrough = -1; // end time of the last word we coached on
  private ignoreThrough = -1; // words from the previous call that arrive late

  /** Starts a new call on a running stream: ignore anything said before t. */
  skipThrough(t: number) {
    this.ignoreThrough = t;
    this.coachedThrough = t;
  }

  addFinalWords(words: Word[]) {
    for (const word of words) {
      if (word.end <= this.ignoreThrough) continue;
      const last = this.turns.at(-1);
      if (last && last.speaker === word.speaker) last.words.push(word);
      else this.turns.push({ speaker: word.speaker, words: [word] });
    }
  }

  setRep(speaker: number, locked: boolean) {
    if (this.repLocked && !locked) return;
    this.repSpeaker = speaker;
    this.repLocked = this.repLocked || locked;
  }

  /** Words the other side said since we last coached. */
  newProspectWords(): Word[] {
    const last = this.turns.at(-1);
    if (!last) return [];
    if (this.repSpeaker !== null && last.speaker === this.repSpeaker) return [];
    return last.words.filter((w) => w.end > this.coachedThrough);
  }

  /** True when the other side just finished saying something worth answering. */
  shouldCoach(): boolean {
    const fresh = this.newProspectWords();
    if (fresh.length === 0) return false;
    const isOpening = this.turns.length <= 2; // "Hello?" deserves an opener
    if (isOpening) return true;
    return fresh.some((w) => !FILLER.has(clean(w.text)));
  }

  markCoached() {
    const last = this.turns.at(-1)?.words.at(-1);
    if (last) this.coachedThrough = last.end;
  }

  lastWordEnd(): number {
    return this.turns.at(-1)?.words.at(-1)?.end ?? 0;
  }

  label(speaker: number): string {
    if (this.repSpeaker === null) return `Speaker ${speaker}`;
    return speaker === this.repSpeaker ? `Rep (speaker ${speaker})` : `Prospect (speaker ${speaker})`;
  }

  transcript(maxTurns = 40): string {
    return this.turns
      .slice(-maxTurns)
      .map((t) => `${this.label(t.speaker)}: ${t.words.map((w) => w.text).join(" ")}`)
      .join("\n");
  }

  /** Small view for the browser. */
  view(maxTurns = 30) {
    return this.turns.slice(-maxTurns).map((t) => ({
      speaker: t.speaker,
      text: t.words.map((w) => w.text).join(" "),
    }));
  }
}
