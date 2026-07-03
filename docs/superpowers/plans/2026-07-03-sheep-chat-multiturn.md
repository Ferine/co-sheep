# Multi-turn Sheep Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the right-click sheep chat a real multi-turn conversation and fix the typewriter cutoff, wandering-sheep, and error-handling bugs.

**Architecture:** The chat bubble stays open across exchanges; the frontend owns a session transcript and passes capped history to the `chat_with_sheep` Tauri command, which folds it into the on-device model prompt and returns a typed `CommentaryEvent` (no more `sheep-commentary` emit for chat). The reply renders inside the chat bubble; the main sheep is parked in `sit` while chatting.

**Tech Stack:** TypeScript + Vite frontend (vitest), Tauri v2 Rust backend, on-device Apple Intelligence via `apple_ai::generate`.

**Spec:** `docs/superpowers/specs/2026-07-03-sheep-chat-multiturn-design.md`

## Global Constraints

- History cap: last **8 turns**, total text budget **1500 chars**, drop oldest first, never drop the newest turn.
- On-device model context is ~4k tokens — do not grow the chat system prompt.
- The chat path must NOT emit `sheep-commentary` after this change; screen-commentary emits are untouched.
- Error messages: Norwegian if `onboarding::get_language()` lowercased contains `"norsk"`, `"norwegian"`, or `"bokm"`; English otherwise.
- Package manager is pnpm (v11). Tests: `pnpm test` (vitest). Rust: `cargo check` from `src-tauri/`.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Transcript capping module

**Files:**
- Create: `src/chat-transcript.ts`
- Test: `src/chat-transcript.test.ts`

**Interfaces:**
- Produces: `interface ChatTurn { role: "human" | "sheep"; text: string }` and `capTranscript(turns: ChatTurn[]): ChatTurn[]` — used by Task 6 (main.ts) and mirrored by Rust's `ChatTurn { role, text }` in Task 4.

- [ ] **Step 1: Write the failing test**

```ts
// src/chat-transcript.test.ts
import { describe, expect, it } from "vitest";
import { capTranscript, ChatTurn } from "./chat-transcript";

function turn(role: "human" | "sheep", text: string): ChatTurn {
  return { role, text };
}

describe("capTranscript", () => {
  it("returns empty for empty history", () => {
    expect(capTranscript([])).toEqual([]);
  });

  it("keeps short histories unchanged", () => {
    const turns = [turn("human", "hei"), turn("sheep", "bæ")];
    expect(capTranscript(turns)).toEqual(turns);
  });

  it("caps to the last 8 turns", () => {
    const turns = Array.from({ length: 12 }, (_, i) =>
      turn(i % 2 === 0 ? "human" : "sheep", `msg ${i}`),
    );
    const capped = capTranscript(turns);
    expect(capped).toHaveLength(8);
    expect(capped[0].text).toBe("msg 4");
    expect(capped[7].text).toBe("msg 11");
  });

  it("drops oldest turns to stay under the char budget", () => {
    const big = "x".repeat(700);
    const turns = [
      turn("human", big),
      turn("sheep", big),
      turn("human", big),
    ];
    const capped = capTranscript(turns);
    expect(capped).toHaveLength(2);
    expect(capped[0].role).toBe("sheep");
  });

  it("always keeps the newest turn even if it alone busts the budget", () => {
    const turns = [turn("human", "x".repeat(9000))];
    expect(capTranscript(turns)).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test`
Expected: FAIL — cannot resolve `./chat-transcript`

- [ ] **Step 3: Write minimal implementation**

```ts
// src/chat-transcript.ts
/** One exchange line in a chat session with the main sheep. */
export interface ChatTurn {
  role: "human" | "sheep";
  text: string;
}

const MAX_TURNS = 8;
const CHAR_BUDGET = 1500;

/**
 * Cap a chat transcript for the on-device model's small context window:
 * last MAX_TURNS turns, dropping the oldest until the total text fits
 * CHAR_BUDGET. The newest turn is always kept.
 */
export function capTranscript(turns: ChatTurn[]): ChatTurn[] {
  const recent = turns.slice(-MAX_TURNS);
  const kept: ChatTurn[] = [];
  let total = 0;
  for (let i = recent.length - 1; i >= 0; i--) {
    total += recent[i].text.length;
    if (total > CHAR_BUDGET && kept.length > 0) break;
    kept.unshift(recent[i]);
  }
  return kept;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test`
Expected: PASS (all suites, including existing drama/events/gossip/spectacles tests)

- [ ] **Step 5: Commit**

```bash
git add src/chat-transcript.ts src/chat-transcript.test.ts
git commit -m "Add chat transcript capping for the on-device context window"
```

---

### Task 2: Typewriter-aware speech bubble hide timeout

**Files:**
- Modify: `src/speech-bubble.ts:88-91`

**Interfaces:**
- Consumes: nothing new. Produces: no API change — `show(text, duration)` semantics become "visible at least `duration`, and always long enough to finish typing".

- [ ] **Step 1: Fix the hide timer**

In `SpeechBubble.show()`, replace:

```ts
    // Auto-hide after duration
    this.hideTimeout = window.setTimeout(() => {
      this.hide();
    }, duration);
```

with:

```ts
    // Auto-hide after duration — but never before the 30ms/char typewriter
    // has finished, or long replies vanish mid-type
    const typewriterMs = text.length * 30;
    this.hideTimeout = window.setTimeout(() => {
      this.hide();
    }, Math.max(duration, typewriterMs + 2500));
```

- [ ] **Step 2: Typecheck**

Run: `pnpm exec tsc --noEmit`
Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add src/speech-bubble.ts
git commit -m "Fix speech bubble hiding before the typewriter finishes"
```

---

### Task 3: Listening sheep — stop wandering during chat

**Files:**
- Modify: `src/sheep.ts` (fields near `state` at ~line 32, methods near `resetActivity` at ~line 127, `update()` at ~line 361, `case "sit"` in the state switch)

**Interfaces:**
- Produces: `Sheep.startListening(): void` and `Sheep.stopListening(): void` — called by Task 6 (`openChat` in main.ts).

- [ ] **Step 1: Add the parkable-state list at module level** (near other module constants at the top of sheep.ts)

```ts
// States safe to interrupt when the sheep should sit and listen to the
// human. Physics states (grabbed, parachute, fall, trampoline, stampede,
// stacked) and reply animations play out first, then park on landing.
const LISTENING_PARKABLE: SheepState[] = [
  "idle", "walk", "sit", "sleep",
  "idle_sleep", "idle_campfire", "idle_counting", "idle_judging",
  "idle_hearts", "idle_zooming", "idle_sighing", "idle_egg_painting",
];
```

- [ ] **Step 2: Add the flag and methods** (next to `resetActivity()`)

```ts
  private listening = false;

  /** Park the sheep while the human is chatting — it stops and listens. */
  startListening() {
    this.listening = true;
    this.resetActivity();
  }

  stopListening() {
    this.listening = false;
    if (this.state === "sit") {
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }
```

- [ ] **Step 3: Park in update() and suppress sit transitions**

In `update(dt)`, immediately after the sprite update (`if (currentSprite) currentSprite.update(dt);`) and before the `switch (this.state)`:

```ts
    // While the human is chatting, park in "sit" once any physics state
    // or reply animation has finished
    if (this.listening && this.state !== "sit" && LISTENING_PARKABLE.includes(this.state)) {
      this.setState("sit", 0);
    }
```

And change the sit case from:

```ts
      case "sit":
        this.updateSit();
        break;
```

to:

```ts
      case "sit":
        if (!this.listening) this.updateSit();
        break;
```

(The platform-validity check at the end of `update()` still runs, so a listening sheep whose window platform closes falls normally, lands, and re-parks.)

- [ ] **Step 4: Typecheck**

Run: `pnpm exec tsc --noEmit`
Expected: no errors

- [ ] **Step 5: Commit**

```bash
git add src/sheep.ts
git commit -m "Add listening state so the sheep sits still during chat"
```

---

### Task 4: Rust backend — history-aware chat with typed return

**Files:**
- Modify: `src-tauri/src/vision.rs:332-366` (`chat_with_sheep`)
- Modify: `src-tauri/src/lib.rs:358-370` (the Tauri command)

**Interfaces:**
- Consumes: `personality::get_chat_prompt(&str, &str) -> String`, `apple_ai::generate(&str, &str)`, `parse_commentary_response`, `onboarding::get_language() -> String`.
- Produces: command `chat_with_sheep(message: String, history: Vec<ChatTurn>) -> Result<CommentaryEvent, String>` where `ChatTurn { role: String, text: String }` (roles `"human"`/`"sheep"`) and `CommentaryEvent { text, animation }` serializes to the existing TS `CommentaryEvent` type. Used by Task 6.

- [ ] **Step 1: Rework `vision::chat_with_sheep`**

Replace the whole function (vision.rs:334-366) with:

```rust
#[derive(serde::Deserialize)]
pub struct ChatTurn {
    pub role: String,
    pub text: String,
}

pub async fn chat_with_sheep(
    user_message: &str,
    history: &[ChatTurn],
) -> Result<CommentaryEvent, Box<dyn std::error::Error + Send + Sync>> {
    let recent_context = memory::get_recent_context().unwrap_or_default();
    let weather_ctx = crate::weather::get_weather_context().await;
    let system_prompt = personality::get_chat_prompt(&recent_context, &weather_ctx);

    // Fold the (frontend-capped) session transcript into the prompt — the
    // on-device model is stateless per call
    let prompt = if history.is_empty() {
        user_message.to_string()
    } else {
        let mut p = String::from("Conversation so far:\n");
        for turn in history {
            let who = if turn.role == "sheep" { "You" } else { "Human" };
            p.push_str(&format!("{}: {}\n", who, turn.text));
        }
        p.push_str(&format!("\nHuman: {}", user_message));
        p
    };

    let raw_response = apple_ai::generate(&system_prompt, &prompt).await?;

    eprintln!("[co-sheep] Chat raw response: {}", raw_response);
    let parsed = parse_commentary_response(&raw_response);

    // Save opinion if formed
    if let (Some(ref topic), Some(ref opinion)) = (&parsed.opinion_topic, &parsed.opinion) {
        let category = parsed.opinion_category.as_deref().unwrap_or("opinion");
        memory::save_opinion(topic, opinion, category).ok();
    }
    if let Some(ref key) = parsed.count {
        memory::increment_today(key);
    }

    memory::record_interaction("chatted with");
    memory::append_journal(&format!(
        "Human said: \"{}\"\n**Reply**: {} [animation: {:?}]",
        user_message, parsed.event.text, parsed.event.animation
    )).ok();

    // The chat bubble owns display now — no sheep-commentary emit
    Ok(parsed.event)
}
```

Note: the `app: &tauri::AppHandle` parameter and the `app.emit("sheep-commentary", ...)` line are gone.

- [ ] **Step 2: Rework the Tauri command in lib.rs**

Replace lib.rs:358-370 with:

```rust
#[tauri::command]
async fn chat_with_sheep(
    message: String,
    history: Vec<vision::ChatTurn>,
) -> Result<vision::CommentaryEvent, String> {
    eprintln!("[co-sheep] Chat request: {}", message);
    vision::chat_with_sheep(&message, &history).await.map_err(|e| {
        eprintln!("[co-sheep] Chat failed: {}", e);
        let lang = onboarding::get_language().to_lowercase();
        if lang.contains("norsk") || lang.contains("norwegian") || lang.contains("bokm") {
            "Bæææ... hjernen min verkar ikkje akkurat no. Prøv igjen?".to_string()
        } else {
            "Baaaa... my brain isn't working right now. Try again?".to_string()
        }
    })
}
```

(The `invoke_handler` registration at lib.rs:576 already lists `chat_with_sheep` — unchanged.)

- [ ] **Step 3: Check it compiles**

Run: `cargo check` (from `src-tauri/`)
Expected: compiles; no warnings about unused `app` (the import of `tauri::AppHandle` in vision.rs is still used by `vision_loop`). If `CommentaryEvent`'s fields trip visibility errors in lib.rs, they don't need to — the command only serializes it; `pub(crate)` on the struct is sufficient.

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/vision.rs src-tauri/src/lib.rs
git commit -m "Make sheep chat history-aware with typed return and localized errors"
```

---

### Task 5: InputBubble reply area, click-away close, CSS

**Files:**
- Modify: `src/input-bubble.ts`
- Modify: `src/styles.css` (after the `.input-bubble-loading` block at ~line 133)

**Interfaces:**
- Produces: `InputBubble.showReply(text: string, isError?: boolean): void` — renders the reply inside the bubble, re-enables and refocuses the input. `setLoading(true)` still shows "thinking...". Click outside the bubble now calls `config.onClose`. Used by Task 6.

- [ ] **Step 1: Add the reply element and click-away listener**

In `input-bubble.ts`, add fields:

```ts
  private replyEl: HTMLDivElement;
  private onDocMousedown: (e: MouseEvent) => void;
```

In the constructor, after `this.element.appendChild(this.promptEl);`:

```ts
    this.replyEl = document.createElement("div");
    this.replyEl.className = "speech-bubble-text input-bubble-reply";
    this.replyEl.style.display = "none";
    this.element.appendChild(this.replyEl);
```

At the end of the constructor (after `document.body.appendChild(this.element);`):

```ts
    // Click anywhere outside the bubble ends the conversation
    this.onDocMousedown = (e: MouseEvent) => {
      if (this.element.style.display === "none") return;
      if (!this.element.contains(e.target as Node)) {
        this.config.onClose?.();
      }
    };
    document.addEventListener("mousedown", this.onDocMousedown);
```

- [ ] **Step 2: Add showReply, fix setLoading, clean up destroy**

```ts
  /** Render the sheep's reply inside the bubble and hand the input back. */
  showReply(text: string, isError = false) {
    this.promptEl.style.display = "none";
    this.promptEl.classList.remove("input-bubble-loading");
    this.replyEl.style.display = "block";
    this.replyEl.textContent = text;
    this.replyEl.classList.toggle("input-bubble-reply-error", isError);
    this.input.disabled = false;
    this.button.disabled = false;
    this.input.focus();
  }
```

`showReply` hides `promptEl`, so `setLoading(true)` must re-show it or "thinking..."
never appears on the second send. Replace `setLoading` with:

```ts
  setLoading(on: boolean) {
    this.input.disabled = on;
    this.button.disabled = on;
    if (on) {
      this.promptEl.style.display = "block";
      this.promptEl.textContent = "thinking...";
      this.promptEl.classList.add("input-bubble-loading");
    } else {
      this.promptEl.textContent = this.config.promptText;
      this.promptEl.classList.remove("input-bubble-loading");
    }
  }
```

And update `destroy()`:

```ts
  destroy() {
    document.removeEventListener("mousedown", this.onDocMousedown);
    this.hide();
    this.element.remove();
  }
```

- [ ] **Step 3: Add CSS** (styles.css, after `.input-bubble-loading`)

```css
.input-bubble-reply {
  margin-top: 4px;
  max-height: 120px;
  overflow-y: auto;
  white-space: pre-wrap;
}

.input-bubble-reply-error {
  color: #ff6b6b;
  font-style: italic;
}
```

- [ ] **Step 4: Typecheck**

Run: `pnpm exec tsc --noEmit`
Expected: no errors

- [ ] **Step 5: Commit**

```bash
git add src/input-bubble.ts src/styles.css
git commit -m "Add in-bubble reply area and click-away close to InputBubble"
```

---

### Task 6: Wire it together — Flock.onChatReply and multi-turn openChat

**Files:**
- Modify: `src/flock.ts` (add public method near `cancelConversation()` at ~line 689)
- Modify: `src/main.ts:530-555` (`openChat`) and its imports

**Interfaces:**
- Consumes: `capTranscript`/`ChatTurn` (Task 1), `Sheep.startListening/stopListening` (Task 3), command `chat_with_sheep(message, history) -> CommentaryEvent` (Task 4), `InputBubble.showReply` (Task 5).
- Produces: `Flock.onChatReply(anim: SheepAnimation | null): void`.

- [ ] **Step 1: Add Flock.onChatReply**

The old flow triggered friend reactions via the `sheep-commentary` listener → `mainBubble.onAnimation` (flock.ts:227). Chat no longer emits that event, so expose the same behavior directly. In `flock.ts` near `cancelConversation()`:

```ts
  /** A direct chat reply arrived — animate the main sheep and let friends react. */
  onChatReply(anim: SheepAnimation | null) {
    this.cancelConversation();
    this.main.resetActivity();
    if (anim) this.main.playAnimation(anim);
    this.triggerFriendReactions("commentary");
    bus.emit("ai-commentary", { animation: anim });
  }
```

- [ ] **Step 2: Rewrite openChat in main.ts**

Add imports at the top of main.ts:

```ts
import { capTranscript, ChatTurn } from "./chat-transcript";
```

and ensure `CommentaryEvent` is imported from `./types` (add it to the existing types import if missing).

Replace the `openChat` function (main.ts:530-555) with:

```ts
const CHAT_TIMEOUT_MS = 30_000;

function openChat() {
  if (chatBubble) return; // already open

  const transcript: ChatTurn[] = [];
  let sendSeq = 0; // guards against stale replies after timeout/close
  flock.main.startListening();

  const closeChat = () => {
    sendSeq++;
    flock.main.stopListening();
    chatBubble?.destroy();
    chatBubble = null;
  };

  chatBubble = new InputBubble({
    promptText: "Talk to me...",
    placeholder: "Say something...",
    buttonText: "Send",
    onSubmit: async (text) => {
      if (!chatBubble) return;
      const seq = ++sendSeq;
      chatBubble.setLoading(true);
      const history = capTranscript(transcript);
      transcript.push({ role: "human", text });
      try {
        const event = await Promise.race([
          invoke<CommentaryEvent>("chat_with_sheep", { message: text, history }),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject("Zzz..."), CHAT_TIMEOUT_MS),
          ),
        ]);
        if (seq !== sendSeq || !chatBubble) return; // closed meanwhile
        transcript.push({ role: "sheep", text: event.text });
        chatBubble.showReply(event.text);
        flock.onChatReply(event.animation);
      } catch (e) {
        console.error("[co-sheep] Chat error:", e);
        if (seq !== sendSeq || !chatBubble) return;
        // The model never answered — drop the turn so a retry isn't doubled
        if (transcript[transcript.length - 1]?.role === "human") transcript.pop();
        chatBubble.showReply(typeof e === "string" ? e : "Baaaa... something broke.", true);
      }
    },
    onClose: closeChat,
  });
  chatBubble.show();
  chatBubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize);
}
```

- [ ] **Step 3: Typecheck and test**

Run: `pnpm exec tsc --noEmit && pnpm test`
Expected: no type errors, all vitest suites pass

- [ ] **Step 4: Commit**

```bash
git add src/flock.ts src/main.ts
git commit -m "Make sheep chat multi-turn with in-bubble replies"
```

---

### Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Full check suite**

Run: `pnpm exec tsc --noEmit && pnpm test` and `cargo check` in `src-tauri/`
Expected: all green

- [ ] **Step 2: Build**

Run: `pnpm build`
Expected: vite build succeeds

- [ ] **Step 3: Manual verification checklist** (requires running the app — `pnpm tauri dev`)

- Right-click main sheep → bubble opens, sheep sits still
- Send message → "thinking..." → reply appears in the bubble, input refocuses
- Send follow-up referencing the first exchange → sheep remembers
- Escape and click-away both close the bubble; sheep resumes wandering
- With Apple Intelligence unavailable → localized error shows in the bubble, input still usable
- Trigger a long AI reply (screen commentary) → typewriter finishes before the bubble hides

- [ ] **Step 4: Final commit if any fixups**

```bash
git add -A && git commit -m "Fix issues found during chat verification"
```
