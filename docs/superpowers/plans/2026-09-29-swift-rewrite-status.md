# Swift rewrite — status & remaining work (2026-09-29)

## Done
- All port tasks merged on `feat/swift-rewrite` (T1–T9 + foundation + glue):
  1055 tests green, zero warnings. The app runs end to end: flock, night
  ambience, bubbles, vision loop, reflection, app watch, weather, MCP server
  (verified with curl), and MCP → companion → sheep bubble.
- Renderer: Canvas → CG raster per tile → `SKTexture(cgImage:)`, RGBA.
  Anchored groups (sheep, bubbles) only re-raster on real visual change.
  Orientation regression tests in `TileOrientationTests`. (`SKMutableTexture`
  was tried and rejected: it rendered tiles upside down on screen.)
- OCR: accurate → fast fallback (the accurate recognizer fails with
  `e5rtError 13` on this macOS 27 build; the Tauri helper is affected too).
- Dev knobs: `CO_SHEEP_HOME` (scratch data dir), `CO_SHEEP_DEBUG`,
  `CO_SHEEP_FPS`, `CO_SHEEP_SNAPSHOT` + `CO_SHEEP_SNAPSHOT_DELAY_MS`.
- CPU (release, full flock at night, 60 fps): ~13–18%. Floor with no canvas
  drawing is ~5.7%.

## Whole-branch review — concurrency/robustness findings (all 13 FIXED, commits de8d4e1..HEAD)
Medium:
1. `easter:fg` / `summer:fg` (and `easter:bg`) are near-full-screen tiles that
   re-raster every frame while a season is active → make petals, seeds and
   butterflies SK-native like WeatherEffects, or give them small anchored groups.
2. Brain files that fail to parse get overwritten with defaults
   (Memory/FriendMemory/EasterMemory/DramaManager/Reflect; faithful to Rust)
   → move the bad file aside (`*.corrupt-<ts>`) before falling back.

Low:
3. InputBubble retain cycle: OverlayController.openChat `bubbleRef` is never
   cleared in `onClose` → each chat leaks the view tree.
4. `Flock.removeFriend` doesn't purge the id from the active conversation,
   activity or spectacle → the removed friend's brain file gets recreated.
5. FriendsView `Dictionary(uniqueKeysWithValues:)` traps on duplicate friend ids.
6. No timeout on vision classify/comment/friend-chat model calls. A hang stops
   the loop, pins `isTickRunning` and pins `aiChatPending`.
7. `isTickRunning` is a Bool, so overlapping "Comment Now" runs clear it early.
8. A config parse failure starts MCP with defaults (no token): fail-open.
9. Weather: no negative cache, not keyed by location.
10. The AI-unavailable bubble repeats every 30 s forever.
11. Easter/Summer use `Calendar.current`; they should pin Gregorian.
12. `OverlayHost` force-unwraps `NSScreen.main` (no display → crash).
13. `FriendMemory.removeBrain` caches non-`.json` files as brains.

Fix notes: seasonal layers now use per-element anchored tiles (≈91k px/frame
rasterized with both seasons forced on, down from ~a full screen);
unparseable brain/state files are quarantined to `<name>.corrupt-<ts>`;
prerequisite bubbles announce once per reason; weather cache keyed by location
with a 5-min failure back-off; MCP not started when config.json is corrupt.

The other three reviewers (sim/glue, backend/data, rendering/UI parity) were
re-run after the usage-limit pause.

## Remaining before the swap
- [x] Fix the concurrency/robustness findings.
- [ ] Triage + fix the three parity reviews.
- [ ] Manual checklist in the real app: grant Screen Recording; drag, toss,
      stack, trampoline; pet; double-click; file drop; chat (right-click);
      capture moment; all debug spectacles; force feud; the settings, brain,
      friends, wardrobe, relationships and naming windows; seasons forced on.
- [ ] Swap commit: delete `src/`, `src-tauri/`, `public/`, `index.html`,
      the Node/Vite/TS/pnpm files and `scripts/{tauri-wrapper,build-apple-helper}.sh`.
      Replace `scripts/build-dmg.sh` with the Swift version (bundle release →
      hdiutil from `build/co-sheep.app`). Rewrite the README (badge,
      requirements, setup, how it works, project tree, cost & privacy) and
      add the build/run notes to `CLAUDE.md`.
