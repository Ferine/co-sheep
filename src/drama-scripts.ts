import { ConversationScript } from "./types";

export type DramaScriptKind =
  | "feud_start"
  | "feud_snipe"
  | "jealousy"
  | "mediation"
  | "reconciliation"
  | "inseparable";

// $A/$B are the pair; $M is the mediator (mediation scripts only).
const SCRIPTS: Record<DramaScriptKind, ConversationScript[]> = {
  feud_start: [
    [
      { speakerId: "$A", text: "You know what? No. I'm done.", duration: 3500, delay: 0, animation: "headshake" },
      { speakerId: "$B", text: "DONE? *I'M* done!", duration: 3000, delay: 600, animation: "vibrate" },
      { speakerId: "$A", text: "Fine!", duration: 2000, delay: 500 },
      { speakerId: "$B", text: "FINE!", duration: 2000, delay: 400 },
    ],
    [
      { speakerId: "$A", text: "I saw what you did at the campfire.", duration: 3500, delay: 0 },
      { speakerId: "$B", text: "Oh, we're doing THIS now?", duration: 3000, delay: 700, animation: "headshake" },
      { speakerId: "$A", text: "We are ABSOLUTELY doing this now.", duration: 3500, delay: 600, animation: "vibrate" },
    ],
  ],
  feud_snipe: [
    [
      { speakerId: "$A", text: "*pointedly grazes elsewhere*", duration: 3000, delay: 0 },
      { speakerId: "$B", text: "The grass is better over here anyway.", duration: 3500, delay: 700, animation: "headshake" },
    ],
    [
      { speakerId: "$A", text: "Some sheep have no shame.", duration: 3000, delay: 0 },
      { speakerId: "$B", text: "Some sheep should mind their own wool.", duration: 3500, delay: 700 },
    ],
    [
      { speakerId: "$A", text: "Hmph.", duration: 2000, delay: 0, animation: "headshake" },
      { speakerId: "$B", text: "Hmph indeed.", duration: 2000, delay: 500, animation: "headshake" },
    ],
  ],
  jealousy: [
    [
      { speakerId: "$A", text: "Getting petted a lot lately, huh.", duration: 3500, delay: 0 },
      { speakerId: "$B", text: "...is that a problem?", duration: 3000, delay: 700 },
      { speakerId: "$A", text: "No. It's FINE.", duration: 2500, delay: 500, animation: "vibrate" },
    ],
    [
      { speakerId: "$A", text: "Teacher's pet.", duration: 2500, delay: 0, animation: "headshake" },
      { speakerId: "$B", text: "You're just jealous of my fluff.", duration: 3500, delay: 700, animation: "bounce" },
    ],
  ],
  mediation: [
    [
      { speakerId: "$M", text: "Okay. Both of you. Here. Now.", duration: 3500, delay: 0 },
      { speakerId: "$A", text: "Only if THEY apologize.", duration: 3000, delay: 700 },
      { speakerId: "$B", text: "ME?!", duration: 2000, delay: 400, animation: "vibrate" },
      { speakerId: "$M", text: "*long, tired sheep sigh*", duration: 3000, delay: 600 },
    ],
    [
      { speakerId: "$M", text: "This feud is exhausting the whole flock.", duration: 4000, delay: 0 },
      { speakerId: "$A", text: "...they started it.", duration: 2500, delay: 700 },
      { speakerId: "$M", text: "I don't care. Hug it out. Metaphorically.", duration: 4000, delay: 600, animation: "headshake" },
    ],
  ],
  reconciliation: [
    [
      { speakerId: "$A", text: "Look... I said things.", duration: 3000, delay: 0 },
      { speakerId: "$B", text: "We both said things.", duration: 3000, delay: 700 },
      { speakerId: "$A", text: "Your wool looked fine that day.", duration: 3500, delay: 600 },
      { speakerId: "$B", text: "...thanks. Yours too.", duration: 3000, delay: 500, animation: "bounce" },
    ],
  ],
  inseparable: [
    [
      { speakerId: "$A", text: "Best flockmate?", duration: 2500, delay: 0 },
      { speakerId: "$B", text: "Best flockmate.", duration: 2500, delay: 500, animation: "bounce" },
    ],
    [
      { speakerId: "$A", text: "We should synchronize our grazing.", duration: 3500, delay: 0 },
      { speakerId: "$B", text: "Way ahead of you.", duration: 2500, delay: 600, animation: "bounce" },
    ],
  ],
};

export function pickDramaScript(
  kind: DramaScriptKind,
  idA: string,
  idB: string,
  mediatorId?: string,
): ConversationScript {
  const pool = SCRIPTS[kind];
  const template = pool[Math.floor(Math.random() * pool.length)];
  return template.map((line) => ({
    ...line,
    speakerId:
      line.speakerId === "$A" ? idA :
      line.speakerId === "$B" ? idB :
      line.speakerId === "$M" ? (mediatorId ?? idA) :
      line.speakerId,
  }));
}
