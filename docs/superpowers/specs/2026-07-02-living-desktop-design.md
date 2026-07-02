# Living Desktop — Design Spec

**Date:** 2026-07-02
**Status:** Approved
**Goal:** Make co-sheep more entertaining along three connected axes: emergent sheep drama, rare spectacle events, and sharper reactions to what the user is actually doing. One cohesive system, not three bolt-ons.

## Chosen approach

A shared **flock event bus** with three consumers (drama engine, spectacle scheduler, gossip/reactions). Drama is **simulation-driven**: storylines emerge from rules over existing affinity/mood data. The on-device AI only narrates outcomes the simulation has already decided; it never owns state. Rejected alternatives: three independent modules (loses the emergent cross-talk that was the point), AI-director (on-device model too small to be a coherent showrunner).

## 1. Flock Event Bus — `src/events.ts`

Typed pub/sub on the webview's native `EventTarget`. No new dependency.

Event vocabulary:

| Event | Payload (essentials) |
|---|---|
| `affinity-changed` | pair ids, old/new score |
| `sheep-petted` | sheep id |
| `group-activity` | activity type, participant ids |
| `conversation-happened` | pair ids, topic/category |
| `app-switched` | app name, bundle id, previous app, session duration |
| `nightfall` / `weather-changed` | phase / weather condition |
| `ai-commentary` | mood, animation chosen |
| `drama-state-changed` | pair ids, old state, new state, cause |
| `spectacle-started` / `spectacle-ended` | spectacle id |

Existing systems publish via one-line `emit()` calls at points where these things already happen; no restructuring. Every subscriber is wrapped in try/catch so one failing consumer cannot break the loop or other consumers.

## 2. App Awareness Signal — Rust side

- Poll `NSWorkspace.shared.frontmostApplication` every 5 s from a background thread in `src-tauri`.
- Capture **app name + bundle ID only**. No window titles in v1 (titles require the Accessibility permission; not worth a second permission war).
- Track per-app session duration in Rust; emit `app-switched` Tauri events to the webview on change, including the duration of the session that just ended.
- No screenshot, no OCR, no AI call. The existing heavy two-pass pipeline is untouched.

## 3. Drama Engine — `src/drama.ts`

Relationship state machine per sheep pair, layered on existing persisted affinity scores.

**States:** `neutral ⇄ warm → inseparable`, `neutral ⇄ tension → feud → reconciling → warm`.

**Transition inputs:**
- Affinity thresholds, held across two consecutive daily ticks (e.g. affinity ≥ +8 → warm; ≤ −3 → tension). Exact numbers are named tuning constants in `drama.ts`, not contract.
- Current moods of both sheep (grumpy accelerates tension; happy accelerates warmth).
- Random low-probability "sparks" so identical inputs don't produce identical flocks.
- **Jealousy counter:** petting imbalance (one sheep petted ≥5 times more than another in a day) pushes the neglected sheep toward tension with the favored one.

**Visible outputs (reuse existing display systems):**
- Feuding pairs refuse shared group activities, storm away from each other (existing `headshake`/`zoom` animations), snipe via speech bubbles.
- Inseparable pairs follow each other, synchronize idle bounces, exchange heart emotes.
- Mediation: the sheep with highest combined affinity to both feuders initiates a huddle; success chance based on its mood, success moves feud → reconciling.
- New conversation script categories keyed by drama state: feud sniping, reconciliation, third-party gossip about an ongoing feud.

**AI narration:** on `drama-state-changed`, 30% chance of an on-device-generated unique line (same pattern and availability check as existing AI-generated conversations). Falls back to scripts.

**Mechanics:** evaluation tick 1/min; daily decay pulls extreme states back toward neutral over ~a week if unfed. Persistence: `relationshipStates` map + capped drama log (last 50 events) in the existing friend brain JSON (`~/.co-sheep/friends/{id}.json`). Missing fields initialize to `neutral` — no migration.

## 4. Spectacle Scheduler — `src/spectacles.ts`

Weighted random table + pity timer. At most ~1 spectacle/day; guaranteed at least one per ~3 days of app uptime. Suppressed during night mode. Last-fired timestamps persist in `~/.co-sheep/config.json` so restarts don't reset the clock.

**Pure-random spectacles:**
- **Wolf sighting** — wolf sprite crosses the screen edge; flock scatters, then huddles; Good Colleague pretends he wasn't scared.
- **UFO visit** — beam abducts one friend for ~20 s; they return "changed" (temporary mood shift + temporary accessory).
- **Traveling merchant** — merchant sheep wanders through, gifts a random wardrobe accessory.
- **Hot-air balloon flyover** — ambient; sheep stop and watch.
- **Shearing day** — all sheep briefly shorn (pink), mortified reactions, wool regrows over an hour.

**Drama-triggered spectacles:**
- **High-noon showdown** — fires when a feud persists ≥2 days: staredown center-screen, tumbleweed, flock watches from the sides; outcome nudges the feud toward reconciling or deepens it.
- **Reconciliation feast** — fires on feud → reconciling: campfire circle with all sheep, affinity boost for participants.

Each spectacle = enter animation → 30–90 s scene composed from existing group-activity choreography primitives → exit + **aftermath**: memories written to friend brains, affinity effects, diary entry.

## 5. Gossip & Sharper Reactions — `src/gossip.ts`

Consumes `app-switched`:
- Per-app daily durations stored via the existing daily-counter infrastructure in `opinions.json`.
- **Instant scripted bits** on app switch, throttled (max ~1 per 10 min): category-based script packs (dev tools, social media, meetings, music, terminal, unknown).
- **Gossip conversations**: sheep pairs discuss the user's measured habits using templates filled with real data ("Third hour in the terminal. Blink twice if you need help."), with the existing 30% AI-variant pattern.
- **Cross-feeds**: user habits become friend memories and mood inputs (late-night coding makes the flock sleepy next morning); break reminders name the actual app ("45 minutes of Xcode straight").

## 6. Error Handling & Performance

- No new mandatory AI calls; all AI usage is optional narration behind the existing availability check.
- 5 s NSWorkspace poll: negligible CPU, zero new permissions.
- Drama tick: 1/min over ≤15 pairs (max 6 characters) — trivial.
- Event consumers isolated via try/catch (section 1).
- All new timers respect existing night-mode/pause behavior.
- Absent drama fields in friend JSON initialize to defaults; malformed spectacle timestamps in config are discarded and rescheduled.

## 7. Testing

- **vitest** (new dev dependency — nothing installed covers testing) for the two pure-logic modules: drama state transitions and spectacle scheduling with an injected clock.
- **Debug tray submenu** for visual QA: "Force Feud", "Trigger Spectacle…" (pick from list), "Simulate App Switch". Always available (single-user personal app; summoning the wolf on demand is a feature, not a leak).

## Out of scope (v1)

- Window titles / Accessibility permission.
- Minigames or any user-driven play mechanics.
- AI-authored story arcs or AI-owned state.
- New art beyond: wolf sprite, UFO, merchant, balloon, shorn-sheep variant (pixel-art additions to the existing sprite sheet style).
