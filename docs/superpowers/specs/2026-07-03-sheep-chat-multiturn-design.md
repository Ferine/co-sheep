# Sheep Chat: Multi-turn Conversation + Bug Fixes

**Date:** 2026-07-03
**Status:** Approved (autonomous session — user preference: structured options, autonomous implementation)

## Problem

The right-click chat with the main sheep is one-shot and buggy:

1. **Replies get cut off** — `SpeechBubble.show()` starts its hide timer (8s) at the same
   moment the typewriter starts (30ms/char). Replies longer than ~260 chars hide mid-type.
2. **The sheep wanders while you type** — `flock.update()` keeps moving the main sheep,
   so the input bubble chases it across the screen.
3. **No conversation** — the input bubble is destroyed after one message
   (`main.ts openChat onSubmit`). Follow-ups get no transcript; the model only sees
   journal context, so it forgets what you said seconds ago.
4. **Reply/input collision** — the reply arrives via the `sheep-commentary` event in the
   main speech bubble, which occupies the same screen spot as the input bubble.
   The backend error fallback is English-only, ignoring the configured language.

## Design

### Multi-turn conversation

- The chat bubble stays open across exchanges. Session ends on Escape, click outside
  the bubble, or explicit close.
- Frontend keeps a session transcript: `ChatTurn[]` where
  `ChatTurn = { role: "human" | "sheep", text: string }`.
- **Capping** (pure TS, `src/chat-transcript.ts`): before each send, history is capped to
  the last 8 turns AND a total budget of ~1500 chars, dropping oldest turns first.
  The on-device model has ~4k tokens; the system prompt (opinions, tallies, journal)
  already consumes most of it.
- `chat_with_sheep(message, history)` — Rust passes history to the helper, which
  replays it as a native FoundationModels `Transcript` (sheep turns wrapped in the
  JSON reply shape — the model imitates its own prior replies, so plain-text history
  collapses JSON compliance to 0/6; wrapped is 6/6. Folding history into the prompt
  as prose instead made the model parrot old lines. Measured live 2026-07-03.)
- The reply renders inside the chat bubble in a new reply area above the form
  (`.input-bubble-reply`, max-height + overflow-y auto). Input re-enables and refocuses
  after each reply. The returned animation plays on the main sheep.

### Backend contract change

- The `chat_with_sheep` Tauri command returns `CommentaryEvent` directly (serde struct,
  not a pre-serialized JSON string).
- The chat path no longer emits `sheep-commentary` — display is owned by the chat bubble.
  Screen-commentary and other emitters are unchanged.
- Journal append (`Human said / Reply`), opinion saving, counter increments,
  and `record_interaction` stay as-is per exchange.

### Bug fixes

- **Typewriter cutoff** (`speech-bubble.ts`): hide timeout becomes
  `Math.max(duration, text.length * 30 + 2500)`.
- **Listening sheep** (`sheep.ts`): `startListening()` / `stopListening()`.
  While listening, if the sheep is in a calm interruptible state (idle, walk, sit,
  any `idle_*`), it is parked in `sit` and state transitions are suppressed.
  Grabbed / parachute / fall / trampoline physics are untouched. `openChat()` starts
  listening; closing the bubble stops it.
- **Localized errors**: on failure the command returns `Err` with a message localized
  via the configured language (Norwegian/English). The frontend shows the error text in
  the reply area and re-enables the input. No silent bubble destruction.
- **Loading timeout**: frontend races the invoke against a 30s timeout; on timeout the
  bubble shows the error state and re-enables input (a late reply from a hung call is
  ignored — the session's send counter guards against stale renders).

## Out of scope (possible follow-ups)

- Chat with friends (personality-specific chat via their brain files)
- Screen-aware chat (OCR snapshot in the chat prompt — tight against the 4k window)
- Streaming responses (apple_ai helper is request/response)

## Testing

- Vitest: `chat-transcript.test.ts` — capping by turn count, char budget, oldest-first
  dropping, empty history.
- Rust: `cargo check` (no existing test infra in src-tauri; prompt folding is trivial
  string formatting).
- Manual: multi-turn flow, Escape/click-away close, error path (AI disabled),
  listening sheep, long-reply typewriter fix.
