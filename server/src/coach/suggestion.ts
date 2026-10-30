// Claude answers in a tiny line format so we can show words as they stream:
//   REP: 1
//   SAY: That's great. Are they mostly building tools, or helping teams use AI?
//   CUE: Acknowledge their work. Explore adoption.
//   STAGE: Objection
// or "SKIP" when the rep does not need help. STAGE comes last so it never
// delays the line the rep reads.

export const STAGES = ["Opener", "Gatekeeper", "Voicemail", "Reason", "Discovery", "Objection", "Book it", "Wrap up"];

export interface Suggestion {
  rep: number | null;
  say: string;
  cue: string;
  stage: string;
  skip: boolean;
}

export function parseSuggestion(text: string): Suggestion {
  const rep = /^REP:\s*(\d+)/m.exec(text);
  const say = /^SAY:\s*(.*)$/m.exec(text);
  const cue = /^CUE:\s*(.*)$/m.exec(text);
  const stage = /^STAGE:\s*(.*)$/m.exec(text);
  const stageName = stage ? stage[1].trim() : "";
  return {
    rep: rep ? Number(rep[1]) : null,
    say: say ? say[1].trim() : "",
    cue: cue ? cue[1].trim() : "",
    stage: STAGES.includes(stageName) ? stageName : "",
    skip: /^SKIP\b/m.test(text),
  };
}
