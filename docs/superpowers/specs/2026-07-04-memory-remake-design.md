# Memory Remake — Design

**Date:** 2026-07-04
**Status:** Approved (evolve-in-place scope confirmed by Atle)

## Problem

An audit of the memory system found the write path solid but the read side weak:

1. **Context-blind retrieval.** `get_recent_context()` always returns the top 20
   opinions by raw `times_seen`. Nothing about the current screen or chat message
   influences selection, and `last_seen` is stored but unused — stale
   high-conviction beliefs crowd out fresh and situationally relevant ones forever.
2. **No forgetting or consolidation.** Opinions never decay, merge, or die. The
   `opinions` Vec is unbounded. Old journals are a write-only archive: never
   re-read, never distilled.
3. **Fragmented topic keys.** `save_opinion` dedups by exact string match on keys
   the ~3B on-device model invents. `twitter_usage` / `twitter_habit` / `twitter`
   accumulate as separate opinions, fragmenting conviction.
4. **Write-only friend memory.** `get_friend_context()` has zero callers.
   `friend_chat` receives names, personality strings, and a topic — friend
   memories, affinities, and moods are written but never recalled in dialogue.
   `get_affinity` and the legacy `get_long_term_memory`/`memory.md` shim are dead
   code.

## Goals

- Situational, freshness-aware opinion recall within the ~4k-token on-device budget.
- Consolidation, dedup, and forgetting via a daily model-driven reflection pass.
- Distill the existing months of journal archive into opinions (one-time backfill).
- Friend-to-friend chats that use the social memory they already generate.

## Non-goals

- No new storage substrate. `opinions.json`, `journal/*.md`, `friends/*.json` stay.
- No embeddings / vector retrieval. Lexical relevance only; the scoring blend
  leaves room to add an embedding term later if bilingual lexical matching proves
  too weak.
- No data migration. New fields are `#[serde(default)]`; existing brains load
  unchanged.
- No changes to chat-session history handling (frontend-owned, session-scoped).

## Design

### 1. Scored retrieval (`memory.rs`)

`get_recent_context(query: Option<&str>)`:

- **Vision path** passes the OCR screen text (already truncated to `OCR_BUDGET`).
- **Chat path** passes the user's message.
- Score per opinion: `times_seen × 0.5^(days_since_last_seen / 14) × (1 + relevance)`.
- `relevance`: token-overlap boost between query tokens and the opinion's
  topic + text, capped at 2.0 (so the multiplier never exceeds 3×). Lowercase,
  strip punctuation, drop tokens shorter than 3 chars; tokens from the topic key
  weigh heavier than opinion-text tokens.
- Unparseable `last_seen` scores with a fixed recency weight of 0.5 — the
  half-life midpoint, neither fresh nor ancient.
- Output format unchanged: top 20 by score, rendered as
  `- [topic] text (seen N times, last: …)` so the model keeps seeing existing
  topic keys.

### 2. Daily reflection pass (new `reflect.rs`)

- **Trigger:** first launch of a new calendar day, guarded by a persisted
  `last_reflection_date` field on `SheepBrain` (same pattern as
  `friend_memory::decay_affinities`).
- **Input:** yesterday's journal file + the full opinion list, truncated to fit
  the 4k window (journal takes the cut, opinions are compact).
- **Model output — explicit operations, not a rewrite:**
  - `merge { from: [keys], into: key, text }`
  - `update { topic, text }`
  - `prune { topic }`
  - `add { topic, text, category }`
- **Rust validation before applying (model proposes, Rust disposes):**
  - Merge sums `times_seen`, keeps earliest `first_seen`, latest `last_seen`.
  - Prune: max 3 per day, and only opinions with `times_seen ≤ 2` **or**
    idle > 21 days. Strong active beliefs cannot be pruned.
  - Add: max 5 per run; canonicalized keys (see §4).
  - Ops referencing unknown topics, or malformed ops, are skipped and logged.
- **Safety:** snapshot `opinions.json` → `opinions.json.bak` before applying
  (one generation of backup).
- **Failure:** unparseable model output → log, mark the date done, retry
  naturally tomorrow. Never re-run in a loop.
- **Observability:** journal a line after a successful pass
  (e.g. `*Slept on it. Tidied my thoughts.*`).

### 3. Historical backfill

- One-time resumable job over `journal/*.md`, oldest → newest, excluding today.
- Cursor (last processed date) persisted on `SheepBrain`; advances even past a
  failed/garbage day (logged and skipped) so the job always terminates.
- Each file runs the same op protocol and validator as §2 with one difference:
  **prune ops are rejected during backfill** — months-old evidence must not
  delete current beliefs. Add/merge/update only.
- **Throttling:** process one journal file every 3 minutes, only when no
  vision-pipeline tick is in flight. ~120 files drain over ~6 hours of normal
  app uptime without contending for the model.

### 4. Topic-key hygiene

- `save_opinion` canonicalizes keys: lowercase, trim, internal whitespace →
  underscores.
- Both prompts in `personality.rs` gain one instruction: when forming an opinion
  on something that already has a topic key in context, reuse that key exactly.
- Reflection's `merge` op remains the backstop for duplicates that still slip
  through.

### 5. Friend recall + dead-code cleanup

- `friend_chat` (vision.rs / lib.rs command) gains both participants' social
  context: mood, mutual affinity label, and the last ~3 memories each, via
  `friend_memory::get_friend_context` trimmed to a small budget (~300 chars per
  friend).
- Delete dead code: `get_affinity`, `get_long_term_memory`, and the `memory.md`
  legacy shim.

## Error handling summary

| Failure | Behavior |
| --- | --- |
| Reflection output unparseable | Log, mark date done, retry tomorrow |
| Individual op invalid | Skip that op, apply the rest, log |
| Backfill day fails | Log, advance cursor, continue |
| `opinions.json` corrupted by a bad apply | Restore path exists via `.bak` snapshot |
| `last_seen` unparseable | Neutral recency in scoring; counts as prune-eligible idle only if `times_seen ≤ 2` |

## Testing

- **Pure Rust unit tests** (op-applier and scorer are brain-in/brain-out):
  recency decay curve, relevance boost and cap, merge arithmetic, prune caps and
  eligibility, malformed-op rejection, add caps, key canonicalization, backfill
  cursor advance/resume, backfill prune rejection.
- **Manual verification against the live sidecar** for prompt behavior: reflection
  op emission quality, topic-key reuse in commentary/chat.

## Judgment calls (approved defaults, overridable)

- Recency half-life: 14 days.
- Relevance boost cap: 2.0 (multiplier ≤ 3×).
- Prune policy: ≤ 3/day, only weak (`times_seen ≤ 2`) or idle (> 21 days) opinions.
- Add cap: 5 per reflection run.
- Backfill throttle: one journal file per 3 minutes, idle-only.
- Friend context budget: ~300 chars per participant.
