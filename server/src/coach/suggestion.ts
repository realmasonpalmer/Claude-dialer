// Claude answers in a tiny line format so we can show words as they stream:
//   REP: 1
//   SAY: That's great. Are they mostly building tools, or helping teams use AI?
//   CUE: Acknowledge their work. Explore adoption.
// or "SKIP" when the rep does not need help.

export interface Suggestion {
  rep: number | null;
  say: string;
  cue: string;
  skip: boolean;
}

export function parseSuggestion(text: string): Suggestion {
  const rep = /^REP:\s*(\d+)/m.exec(text);
  const say = /^SAY:\s*(.*)$/m.exec(text);
  const cue = /^CUE:\s*(.*)$/m.exec(text);
  return {
    rep: rep ? Number(rep[1]) : null,
    say: say ? say[1].trim() : "",
    cue: cue ? cue[1].trim() : "",
    skip: /^SKIP\b/m.test(text),
  };
}
