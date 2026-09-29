# Swift rewrite — design

**Date:** 2026-09-29
**Branch:** `feat/swift-rewrite`
**Status:** approved decisions from the user; implementation in progress

## Goal

Replace the Tauri stack (Rust backend + TypeScript/Canvas frontend + WebView
aux windows + Swift sidecar) with a single native Swift macOS app, at
**behavioral and visual parity**. Big-bang: the port lives on this branch and
the swap happens in one merge. The Tauri sources stay in the tree as the
reference implementation until the final "delete Tauri" commit.

## Decisions (user-approved)

| Topic | Decision |
|---|---|
| Staging | Big-bang parity (no phased releases) |
| Overlay rendering | SpriteKit |
| Aux windows | Native SwiftUI |
| Build | SwiftPM package + bundle script (no .xcodeproj) |
| Platform | macOS 27 (`swift-tools-version: 6.4`, `.macOS(.v27)`) |

## Decisions (defaults, taken without asking)

- **Data compatibility:** every file under `~/.co-sheep/` keeps its exact JSON
  schema, so the existing sheep keeps its opinions, friends, drama and journal.
  Codable types use the serde field names verbatim and decode tolerantly
  (missing field → the serde default, unknown fields ignored).
- **Platform:** macOS 27 only (user decision) — FoundationModels, ScreenCaptureKit
  screenshots etc. are unconditionally available; no `#available` gating. Bundle id stays
  `com.cosheep.app`. Activation policy `.regular` (Tauri's default: Dock icon
  + app menu), plus the status-bar item.
- **Zero third-party dependencies.** Everything is Apple frameworks. The MCP
  server is hand-rolled (see below).
- **Swift 6 language mode** with **default MainActor isolation** for the kit
  target. The sim, UI and SpriteKit all live on the main actor anyway; I/O and
  model calls opt out with `nonisolated` / `@concurrent` / actors.

## What the rewrite deletes

- The `apple-ai-helper` sidecar and the stdin/stdout process-per-request
  bridge. FoundationModels and Vision are called in-process.
- The Tauri command layer (45 commands) and the event layer (~25 events):
  they become plain method calls and typed callbacks.
- `xcap` → ScreenCaptureKit. Raw `CGWindowList` FFI → direct Swift calls.
  The cursor-polling thread → per-frame `NSEvent.mouseLocation` hit-testing.
- The web toolchain (Vite, TypeScript, pnpm, vitest).

## Package layout

```
Package.swift
Sources/
  CoSheep/                 executable: main.swift only (NSApplication bootstrap)
  CoSheepKit/              library: everything else
    App/                   AppDelegate, AppController (ex-lib.rs commands),
                           Menus (status item + main menu), WindowManager
    Overlay/               OverlayPanel (NSPanel), OverlayScene (SKScene, game loop),
                           OverlayController (ex-main.ts: input, drag, petting,
                           stampede, chat, capture moment), InputBubble
    Render/                Canvas (Canvas2D-shaped API), DisplayList, CGReplay,
                           CanvasTileLayer, CSSColor, CSSFont, SpriteSheet
    Sim/                   Sheep, Flock, SpeechBubble, Accessories, Conversations,
                           FriendPersonalities, GroupActivities, Drama, DramaScripts,
                           DramaManager, Gossip, Spectacles, SpectacleRender,
                           EasterTheme, SummerTheme, NightAmbience, WeatherEffects,
                           BreakReminder, McpCompanion, ChatTranscript, SimTypes,
                           FlockBus
    Brain/                 Paths, JSONFile, Config (ex-onboarding.rs), Memory,
                           FriendMemory, EasterMemory, LivingState, Personality, Reflect
    Services/              Log, AppleAI, Capture, Permissions, ScreenInfo, WindowList,
                           AppWatch, Weather, Vision (pipeline), AppEvents
    MCP/                   HTTPServer (Network.framework), MCPServer (JSON-RPC),
                           SessionStore (reducer)
    UI/                    SwiftUI: SettingsView, BrainView, FriendsView,
                           WardrobeView, NamingView, FriendMemoryView
  CoSheepKit/Resources/    sprites/*.png, AppIcon.icns
Tests/CoSheepKitTests/     Swift Testing ports of all 52 Rust + 56 vitest tests
scripts/bundle.sh          assemble + sign build/co-sheep.app
scripts/run.sh             build, bundle, launch with logs in the terminal
scripts/build-dmg.sh       (rewritten for the Swift app)
```

## Rendering: SpriteKit as loop + compositor, Canvas for procedural art

The TS frontend is immediate-mode: every frame, each entity runs
`update(dt)` then `draw(ctx)` with raw Canvas2D calls. Almost every visual
(accessories, campfire, emotes, spectacles, themes) is procedural
`fillRect`/`arc`/`ellipse`/path pixel art. Only the six sheep sprite sheets
are images. The draw code makes ~900 Canvas2D calls.

Rebuilding that as native SpriteKit nodes would be a redesign rather than a
port, and `SKShapeNode` is too slow for it anyway. Instead:

1. **`Canvas`** is a Swift class with the Canvas2D surface the TS code uses:
   `fillStyle`/`strokeStyle` (CSS color strings, plus gradient objects),
   `lineWidth`, `lineCap`, `globalAlpha`, `font`, `textAlign`,
   `shadowBlur`/`shadowColor`, `save`/`restore`, `translate`/`rotate`/`scale`,
   `beginPath`/`moveTo`/`lineTo`/`quadraticCurveTo`/`arc`/`ellipse`/`roundRect`/
   `closePath`, `fill`/`stroke`, `fillRect`/`strokeRect`/`clearRect`,
   `fillText`/`measureText`, `createLinearGradient`/`createRadialGradient`,
   `drawImage` (sprite frames, nearest-neighbor), `imageSmoothingEnabled`.
   Ported draw code reads almost line for line: `ctx.fillStyle = "#fff"` →
   `c.fillStyle = "#fff"`.
2. The canvas **records a display list** instead of drawing directly. Each
   command captures the current transform and style state.
3. Draw code is wrapped in **groups**: `c.group("sheep:main") { sheep.draw(c) }`.
   Each group's commands get a transform-aware bounding box, are replayed into
   a small CoreGraphics bitmap (at the screen's backing scale), and become the
   texture of one `SKSpriteNode`. zPosition follows group order.
   CoreGraphics is the model Canvas2D was built on, so the semantics match:
   even-odd vs nonzero winding, arcs, gradients, shadows, source-atop tinting.
4. **Unchanged groups skip work.** If a group's display list equals last
   frame's, the rasterize and upload are skipped (a sleeping sheep costs
   nothing).
5. **Full-screen effects are native SpriteKit.** Rain and snow
   (`weather-effects.ts`), plus stars, fireflies and moonlight
   (`night-ambience.ts`), would force full-screen rasters every frame. They
   are rewritten with `SKEmitterNode` and pooled `SKSpriteNode`s, keeping the
   same look and density.

Coordinates in the sim stay web-style: top-left origin, y down, points. The
scene converts at the tile boundary. The overlay covers the primary screen,
same as today.

**Speech bubbles** (DOM + CSS today) become canvas groups: rounded rect
`#1a1a2e`, 2px border (default `#e94560`, per-friend override), 11px tail,
Courier New 14px, line-height 1.4, max-width 300 / min-width 120, padding
12/16, shadow `0 4px 12px rgba(0,0,0,.3)`, 30ms/char typewriter, and the same
viewport clamping. Word wrap uses CoreText.

**Input bubble** (chat) is a real `NSTextField` + button in a small key-able
panel positioned over the sheep. Styling follows the CSS.

**Click-through:** the overlay `NSPanel` (borderless, non-activating,
transparent, `.canJoinAllSpaces`, level above normal windows) toggles
`ignoresMouseEvents` each frame from a hit-test of `NSEvent.mouseLocation`
against the flock bounds. While dragging, or while the input bubble is open,
it stays interactive, which is the same rule `cursor.rs` applies today.

## Communication (replaces IPC)

- **Tauri commands** → methods on `AppController` and the Brain/Services
  types. Callers use `await` where the Rust command was async.
- **Rust → webview events** → `AppEvents`, a main-actor hub of typed
  callbacks: `sheepCommentary`, `sheepSession`, `appSwitched`, `openChat`,
  `captureMoment`, `debugCommand`, `addFriend`, `removeFriend`,
  `accessoriesChanged`, `friendAccessoriesChanged`, `namingComplete`,
  `weatherChanged`.
- **In-sim `bus`** → `FlockBus`, typed events with the same payloads. Each
  handler is isolated, so one failing handler can't break the others.

## Time, randomness, timers

- `dt` is in **milliseconds**, taken from SKScene `update(_:)` and clamped the
  same way the TS loop clamps it.
- `Date.now()` → `SimClock.nowMs()`, injectable for tests.
- `Math.random()` → `SimRandom.next()`, seedable for tests.
- `setTimeout`/`setInterval` → `SimTimers.after(ms:)` / `every(ms:)`. These
  are main-actor timers returning a cancellable token.

## AI, capture, platform

- **AppleAI:** `LanguageModelSession` in-process, keeping the same
  system/prompt/history → `Transcript` construction as the helper. Also
  `availability()`, `truncateUTF8`, and Vision `VNRecognizeTextRequest` OCR on
  a `CGImage` (the base64 JPEG hop goes away).
- **Capture:** `SCScreenshotManager` for the primary display. Permission
  preflight/request via `CGPreflightScreenCaptureAccess` /
  `CGRequestScreenCaptureAccess`.
- **WindowList** (window platforms) and **AppWatch** (frontmost app) keep the
  same `CGWindowListCopyWindowInfo` semantics, now called directly from Swift.
- **Weather:** `URLSession` against wttr.in, with the same parsing and cache.
- **Vision pipeline:** the two-pass classify → comment flow with the same
  prompts, parsing, pacing (interval ±20%), pause flag, and "comment now".
- **Reflection loop:** same daily reflection and backfill scheduling.

## MCP server

Streamable HTTP in **JSON-response mode**. The spec allows the server to
answer a POST with `application/json` instead of opening an SSE stream,
which is all a facts-in, nothing-out tool server needs.

- `NWListener` on `127.0.0.1:<mcp_port>` with a minimal HTTP/1.1 parser.
- `POST /mcp`: JSON-RPC `initialize` (echoes a supported protocol version,
  carries the same server instructions), `notifications/*` → 202, `ping`,
  `tools/list` (same six tools, same descriptions and JSON schemas),
  `tools/call` → `SessionStore.apply(fact)` → `AppEvents.sheepSession`.
- `GET /mcp` → 405 (no server-initiated stream). The optional bearer token
  check is unchanged.

## Persistence

`Paths` resolves `~/.co-sheep/…`. `JSONFile<T>` does atomic writes
(write-temp + rename) and keeps the `.bak` behavior where Rust has it. Every
Rust struct → a `Codable` struct with identical keys (`CodingKeys` where
Swift naming differs). Tests round-trip real fixtures copied from the Rust
tests.

## Porting rules (all contributors)

1. **Faithful port.** Same constants, probabilities, timings, thresholds,
   state machines and prompt text. Every user-facing string stays verbatim,
   Nynorsk included. No "improvements" during the port. Bugs are ported as-is
   and listed in the task report.
2. **Names.** Keep the TS/Rust identifiers in Swift case. String unions become
   `String`-raw-value enums whose raw values are the original strings
   (`case idleSleep = "idle_sleep"`).
3. **Tests.** Every Rust `#[test]` and every vitest `it()` becomes a Swift
   Testing `@Test` with the same assertions.
4. **Logging.** `Log.info("tag", "msg")` and `Log.debug(...)`, gated by
   `CO_SHEEP_DEBUG=1`, in the same `HH:MM:SS [tag] msg` format.
5. **Ownership.** Only touch the files your task owns. If you need an API from
   a file you don't own, note it in your report and don't edit that file.

## Build, run, sign

- `swift build`, `swift test`.
- `scripts/bundle.sh [debug|release]` → `build/co-sheep.app` (Info.plist,
  icon, resources in `Contents/Resources`, codesign).
- `scripts/run.sh` → build + bundle + launch in the foreground with logs.
- Signing uses `CODESIGN_IDENTITY` (default ad-hoc `-`). Ad-hoc signatures
  change every build, so macOS re-asks for Screen Recording permission after
  each rebuild. A stable self-signed "co-sheep dev" identity fixes that, and
  the script picks it up if it exists.

## Final swap

Once parity is verified, one commit removes `src/`, `src-tauri/`, `public/`,
`index.html`, the Node/Vite/TS config, pnpm files and the Tauri scripts, and
rewrites the README "build" sections and `CLAUDE.md`.

## Risks

- **Visual drift** in the canvas port. Mitigated by the Canvas2D-faithful API
  and side-by-side screenshots against the Tauri build.
- **TCC churn** with ad-hoc signing (see above).
- **Swift 6 concurrency friction.** Mitigated by default MainActor isolation.
- **Big-bang integration bugs.** Last time, the whole-branch review caught what
  per-task reviews missed (memory remake). A whole-branch review is mandatory
  before the swap.
