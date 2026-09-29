# Swift port — conventions for every port task

Read first: `docs/superpowers/specs/2026-09-29-swift-rewrite-design.md` and
`docs/superpowers/plans/2026-09-29-swift-rewrite.md`. The Tauri app
(`src/`, `src-tauri/`, `public/`) is the **reference implementation**. Do not
modify it.

## Toolchain

- Xcode 27 / Swift 6.4 / macOS 27 only (`.macOS(.v27)`). No `#available`
  checks, no `canImport` gating.
- Swift 6 language mode, **default MainActor isolation** (`.defaultIsolation(MainActor.self)`)
  plus `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`.
  - Everything is `@MainActor` unless you say otherwise. The sim, UI,
    SpriteKit and Brain file I/O all run on main (files are tiny).
  - Pure value types that must be usable off-main (Codable payloads crossing
    threads, network parsing) are declared `nonisolated struct/enum`.
  - CPU-heavy or blocking work (OCR, image encoding, socket I/O) goes in
    `@concurrent nonisolated func` / `nonisolated` types. Don't block main.
  - No `@unchecked Sendable` or `nonisolated(unsafe)` without a one-line
    justification comment.
- Zero third-party dependencies. Apple frameworks only.
- `swift build` and `swift test` from the package root. Tests use
  **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`,
  `#require`). Any suite that mutates globals (`Paths.root`,
  `SimRandom.source`, `SimClock.nowSource`) must be `@Suite(.serialized)` and
  restore them afterwards.

## Foundation APIs (already exist — read the files, do not edit them)

| Need | Use | File |
|---|---|---|
| `ctx` Canvas2D | `Canvas` — same member names: `fillStyle`, `strokeStyle` (String or `CanvasGradient`), `lineWidth`, `lineCap` ("round"…), `globalAlpha`, `font`, `textAlign`, `textBaseline`, `shadowBlur`, `shadowColor`, `imageSmoothingEnabled`, `save()`, `restore()`, `translate`, `rotate`, `scale`, `beginPath`, `moveTo`, `lineTo`, `quadraticCurveTo`, `bezierCurveTo`, `arc(x,y,r,a0,a1,ccw)`, `ellipse(...)`, `rect`, `roundRect(x,y,w,h,r)`, `closePath`, `fill()`, `stroke()`, `fillRect`, `strokeRect`, `clearRect`, `fillText`, `measureText(t).width`, `createLinearGradient`, `createRadialGradient` → `.addColorStop(o, "css")`, `drawImage` | `Render/Canvas.swift` |
| Tiles/z-order | `ctx.group("key", layer: .world \| .overlay) { … }` — each group becomes one GPU tile. Whoever *calls* an entity's draw wraps it. Entities just draw. | `Render/Canvas.swift` |
| Sprites | `SpriteSheet(src, fw, fh, frames, fps)`, `.update(dt)`, `.draw(ctx, x, y, scale, flipX, tint)`, `.reset()` | `Render/SpriteSheet.swift` |
| `Math.random()` | `SimRandom.next()`, `SimRandom.int(n)`, `SimRandom.pick(arr)` | `Sim/SimRuntime.swift` |
| `Date.now()` / `performance.now()` / `getHours()` | `SimClock.nowMs()` / `SimClock.perfMs()` / `SimClock.hour()` | `Sim/SimRuntime.swift` |
| `setTimeout` / `setInterval` / `clear*` | `SimTimers.after(ms) {…}` / `SimTimers.every(ms) {…}` → `TimerToken.cancel()` | `Sim/SimRuntime.swift` |
| flock `bus` | `bus.emit(.sheepPetted(id:))`, `bus.on(.sheepPetted) { event in … }` → unsubscribe closure | `Sim/FlockBus.swift` |
| Tauri `listen`/`emit` (backend→overlay) | `AppEvents.shared.<signal>.on { … }` / `.emit(…)` | `Services/AppEvents.swift` |
| types.ts | `SheepState`, `SheepAnimation`, `CommentaryEvent`, `SessionEvent`, `FriendColor`, `FriendPersonality`, `FriendConfig`, `ConversationLine`/`ConversationScript`, `WindowPlatform`, `FRIEND_TINTS`, `EasterThemeHooks` | `Sim/SimTypes.swift` |
| On-device model | `protocol LanguageModel` (`generate`, `generateChat`, `ocr`, `unavailableReason`), `HistoryTurn` | `Services/LanguageModel.swift` |
| Logging (`log!`/`debug!`/`console.log`) | `Log.info("tag", "msg")`, `Log.debug(...)`, `Log.truncateForLog`, `Log.rawForLog`, global `truncateUTF8(s, maxBytes:)` | `Services/Log.swift` |
| `~/.co-sheep` | `Paths.root/.config/.opinions/.journal/.friends`, `Paths.file(name)`, `Paths.dir(name)` — add more paths as `extension Paths` in *your own* file | `Brain/Paths.swift` |
| JSON files | `JSONFile.read/readStrict/write/writeData`, `JSONValue` (≈ `serde_json::Value`) | `Brain/JSONFile.swift` |
| Bundled images | `ResourceFiles.cgImage("sprites/x.png")` | `Services/ResourceFiles.swift` |
| SK-native effects | `OverlayScene.nightBackLayer` (z −1000), `.weatherLayer` (z 1000), `.nightFrontLayer` (z 1100), `scenePoint(x, y)` canvas→scene | `Overlay/OverlayScene.swift` |

## Porting rules

1. **Faithful port.** Same constants, probabilities, timings, thresholds, state
   machines, prompt text and user-facing strings (verbatim, Nynorsk
   included, same emoji). No "improvements". If you spot a bug, port it
   as-is and list it in your report.
2. **Names.** Keep TS/Rust identifiers in Swift case (`snake_case` fns →
   `camelCase`). Keep file-level constants' names. Class → `final class`.
   TS object literals used as records → `struct`. String unions → enums with
   the original strings as raw values.
3. **Numbers.** TS `number` → `Double` (ms timings, positions). Use `Int`
   only where the original is clearly integral (counts, indices, Rust ints).
   CSS strings built by interpolation keep working with Doubles
   (`"rgba(255, 0, 0, \(a))"`, `"bold \(size)px monospace"`).
4. **Codable = serde.** Same JSON keys (`CodingKeys` for snake_case/camelCase
   renames). Missing fields decode to the serde default, unknown fields are
   ignored, `Option` → optional. Write the same shape back.
5. **Tests.** Every Rust `#[test]` / vitest `it()` in your sources → a Swift
   `@Test` with the same assertions, in `Tests/CoSheepKitTests/<Area>/`.
   Add tests for anything non-trivial you had to adapt.
6. **Ownership.** Create/edit only the files your task lists. Need something
   from a file you don't own (or from a task running in parallel)? Define the
   smallest local protocol/closure seam in your own file and list it in the
   report. Never edit foundation files or the TS/Rust reference.
7. **No placeholders.** No `TODO: port later`, no stubbed bodies. If
   something truly can't be done, stop and explain it in the report.
8. **Warnings.** `swift build` must be warning-free for your files.

## Done means

- `swift build` is clean and `swift test` is green in your worktree.
- Work is committed on your worktree branch. The message is
  `feat(swift): <task> — <summary>`, ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Your final message is a report containing:
  1. branch name + commit hash
  2. files created
  3. public API (type + method signatures other tasks will call)
  4. seams/protocols you introduced and what they expect
  5. deviations from the reference (with reasons)
  6. bugs ported as-is
  7. test count (ported vs new)
