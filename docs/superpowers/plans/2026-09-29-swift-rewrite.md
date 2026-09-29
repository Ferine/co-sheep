# Swift rewrite — implementation plan

Spec: `docs/superpowers/specs/2026-09-29-swift-rewrite-design.md`

Execution: the main session owns the foundation, the glue and integration.
Port tasks go to `sonnet` subagents in isolated git worktrees, each
branched from the latest integrated `feat/swift-rewrite`, touching only the
files it owns. The main session merges each branch, runs
`swift build && swift test`, then fixes integration seams. Before the swap
there is a mandatory whole-branch review.

Every task has the same acceptance gate: `swift build` is clean (warnings
triaged), `swift test` is green, the ported tests exist, and the report lists
public API, deviations, and any bugs ported as-is.

## Z-order bands (OverlayScene)

| z | Content |
|---|---|
| -1000 | NightAmbience background (stars, moonlight) — SK-native |
| 0…999 | Canvas `.world` groups in draw order: easter/summer bg+mid, main sheep, friends, spectacle, easter/summer fg |
| 1000 | WeatherEffects (rain/snow) — SK-native |
| 1100 | NightAmbience foreground (fireflies, campfire glow) — SK-native |
| 2000+ | Canvas `.overlay` groups: speech bubbles, emote text |

## Wave 0 — Foundation (main session)

Owned: `Package.swift`, `Sources/CoSheep/main.swift`, `Sources/CoSheepKit/{App,Overlay,Render}/*`,
`Sim/SimTypes.swift`, `Sim/FlockBus.swift`, `Sim/SimRuntime.swift` (clock/random/timers),
`Services/{Log,AppEvents,LanguageModel}.swift`, `Brain/{Paths,JSONFile}.swift`, resources,
`scripts/{bundle,run}.sh`.

- [ ] Package with `CoSheep` exe + `CoSheepKit` lib + tests, Swift 6, default MainActor isolation
- [ ] Canvas API + DisplayList + CGReplay + CanvasTileLayer (group → bbox → raster → SKSpriteNode, skip-if-unchanged)
- [ ] CSSColor (hex/rgb/rgba/hsl/hsla/named) + CSSFont parsing, cached
- [ ] SpriteSheet (ex-sprite.ts) incl. tint (source-atop) and fallback shape
- [ ] OverlayPanel + OverlayScene game loop (dt ms, clamped), click-through toggling from hit-test bounds
- [ ] SimClock / SimRandom / SimTimers, FlockBus, AppEvents, Log (`HH:MM:SS [tag] msg`, `CO_SHEEP_DEBUG`)
- [ ] `LanguageModel` protocol (generate / generateChat) so Brain + Vision code against it
- [ ] Paths + JSONFile (atomic write, .bak)
- [ ] SimTypes (ex-types.ts) enums with original raw values
- [ ] bundle.sh / run.sh; smoke: bundled app shows a sprite sheep drawn via Canvas
- [ ] Tests: canvas bbox/transform, color/font parsing, events (ex-events.test.ts), log format (ex-logging.rs tests)

## Wave 1 — parallel

### T1 Brain (ex-Rust persistence + reflection)
Sources: `onboarding.rs` `memory.rs` `friend_memory.rs` `easter_memory.rs` `living_state.rs` `personality.rs` `reflect.rs`
Owns: `Sources/CoSheepKit/Brain/*` (except Paths/JSONFile), `Tests/CoSheepKitTests/Brain/*`
Tests: onboarding(2) memory(9) friend_memory(2) reflect(17)

### T2 Platform + MCP
Sources: `apple_ai.rs` + `helper/apple-ai-helper.swift`, `capture.rs`, `permissions.rs`, `screen_info.rs`, `windows.rs`, `app_watch.rs`, `weather.rs`, `mcp.rs`
Owns: `Services/{AppleAI,Capture,Permissions,ScreenInfo,WindowList,AppWatch,Weather}.swift`, `MCP/*`, tests
Tests: mcp(9) + HTTP/JSON-RPC round-trip tests for the hand-rolled server

### T3 Sim entity
Sources: `sheep.ts` `speech-bubble.ts` `accessories.ts` `friend-personalities.ts` `break-reminder.ts` `chat-transcript.ts`
Owns: `Sim/{Sheep,SpeechBubble,Accessories,FriendPersonalities,BreakReminder,ChatTranscript}.swift`, tests
Tests: sheep.test, chat-transcript.test

### T4 Sim logic, data, ambience
Sources: `conversations.ts` `drama.ts` `drama-scripts.ts` `spectacles.ts` `easter-theme.ts` `summer-theme.ts` `night-ambience.ts` (SK-native) `weather-effects.ts` (SK-native)
Owns: those Swift files + tests
Tests: drama.test, spectacles.test

## Wave 2 — parallel (after Wave 1 merged)

### T5 Sim composites
Sources: `group-activities.ts` `spectacle-render.ts`
Owns: `Sim/{GroupActivities,SpectacleRender}.swift`

### T6 Vision pipeline + AppController
Sources: `vision.rs` (+9 tests), the command bodies in `lib.rs` (chat_with_sheep, friend_ai_chat, save_moment, add_friend/remove_friend, settings, accessories, debug_capture, record_* …), vision/reflection/app-watch loop spawning
Owns: `Services/Vision.swift`, `App/AppController.swift`, tests

## Wave 3 — parallel

### T7 SwiftUI windows
Sources: `public/{settings,memory,friends,wardrobe,naming,friend-memory}.html`
Owns: `UI/*`, `App/WindowManager.swift`

### T8 Flock
Sources: `flock.ts`
Owns: `Sim/Flock.swift`

## Wave 4

### T9 Managers
Sources: `drama-manager.ts` `gossip.ts` `mcp-companion.ts`
Owns: `Sim/{DramaManager,Gossip,McpCompanion}.swift`
Tests: gossip.test, mcp-companion.test

### Glue (main session)
Sources: `main.ts` `input-bubble.ts`, tray + app menu from `lib.rs`
Owns: `Overlay/{OverlayController,InputBubble}.swift`, `App/{AppDelegate,Menus}.swift`

## Wave 5 — Integration & swap (main session)

- [ ] Run the bundled app: onboarding/naming, parachute, walk, drag/toss/stack/trampoline, pet, dbl-click, file drop, chat, capture moment, comment now, pause, all debug spectacles, force feud, MCP round-trip from Claude Code, settings/brain/friends/wardrobe/relationships windows, night mode, weather, seasons (forced on)
- [ ] Side-by-side screenshots vs the Tauri build
- [ ] Whole-branch review (sonnet reviewers per dimension + verification)
- [ ] Delete Tauri/web sources, rewrite README build sections + CLAUDE.md, dmg script
