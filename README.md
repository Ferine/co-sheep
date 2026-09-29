# co-sheep

A desktop companion sheep that watches your screen and delivers snarky commentary. Think unhinged Clippy meets a judgmental pixel art sheep — with friends.

![Swift](https://img.shields.io/badge/Swift-6-orange) ![Platform](https://img.shields.io/badge/platform-macOS%2027-lightgrey)

![The sheep gang](docs/sheep-gang.png)

*The gang: your main sheep, Good Colleague (with glasses and tie), and friends with personalities, accessories, and opinions.*

## What it does

- A pixel sheep parachutes onto your desktop and wanders around
- Every few minutes, it captures your screen and runs it through a two-pass, fully on-device AI pipeline (Apple Intelligence + Vision OCR — nothing ever leaves your Mac)
- **Pass 1**: cheap classification — is anything interesting happening?
- **Pass 2**: commentary with expressive animations — only when warranted
- The sheep forms persistent opinions about you that grow stronger over time
- It keeps daily tallies ("that's the 5th time on Twitter today"), tracks which apps you actually use, and writes a markdown diary
- You can drag it, pet it, double-click it, or drop files on it
- **Friends** with distinct personalities roam your desktop, chat with each other, and react to what's happening

## The Flock

Your sheep is never alone. **Good Colleague** (a Norwegian office sheep with glasses, a tie, and coffee) is always present. You can add up to 4 more friends, each with:

- **Personality** — Snarky, Wholesome, Chaotic, or Passive-Aggressive — affects quips, idle behavior, and reactions
- **Color** — pink, green, gold, purple, or orange tint
- **Accessories** — party hat, crown, top hat, wizard hat, sunglasses, cape, scarf, and 12 more from the wardrobe
- **Size variation** — each friend spawns slightly smaller or larger (0.85x–1.15x)
- **Name tags** — visible during calm states

### Friend Behaviors

- **Personality idle activities** — chaotic friends zoom around randomly, wholesome friends emit hearts, snarky friends judge-stare with a magnifying glass, passive-aggressive friends sigh dramatically
- **Reactive emotes** — when the main sheep gets AI commentary, nearby friends react ("WHAT", "Hmm.", "*pretends not to notice*")
- **45+ conversation scripts** — personality-pair dialogues, time-aware morning/night exchanges, weather-aware banter, running gags
- **AI-generated conversations** — 30% chance that friend pairs have unique on-device-generated dialogue instead of scripted lines
- **Group activities** — campfire circles, follow-the-leader, synchronized bouncing, huddle formations, group sunbathing in summer
- **Notifications** — friends greet on launch, comment on nightfall, echo break reminders

### Friend Memory

Each friend has a persistent brain (`~/.co-sheep/friends/{id}.json`) that tracks:

- **Mood** — happy, grumpy, sleepy, or excited (drifts based on recent activity)
- **Relationships** — affinity scores with every other character (+1 per conversation, +2 per group activity, daily decay)
- **Memories** — last 20 notable events ("Talked with Fluffy about tabs", "Got petted by human!")
- **Stats** — conversations today/total, times petted, group activities, days alive

The "Friend Relationships" viewer shows an affinity matrix, per-friend stats, and memory timeline.

## Interactions

- **Drag & drop** — pick up any sheep, it wiggles. Drop it mid-air and it deploys a parachute
- **Double-click** — random quip and animation, no API call needed
- **Petting** — hover over any sheep for 2+ seconds, it falls asleep with floating hearts
- **File drop** — drag a file onto any sheep and it "eats" it with a comment based on file type
- **Right-click** main sheep to chat directly
- **Capture Moment** — save sheep + speech bubble as PNG to Desktop (tray menu)

## MCP: Claude Code narrates through the sheep

co-sheep runs a local MCP server (`127.0.0.1:4917`) while the app is open. Point
Claude Code at it and your progress reports come out of the sheep's mouth — in
the sheep's voice, not Claude's.

Connect once:

```bash
claude mcp add --transport http co-sheep http://127.0.0.1:4917/mcp
```

Or add to `.mcp.json`:

```json
{
  "mcpServers": {
    "co-sheep": { "type": "http", "url": "http://127.0.0.1:4917/mcp" }
  }
}
```

Tools: `session_begin`, `set_task`, `progress`, `milestone` (`done`/`failed`/
`blocked`/`waiting_on_you`), `say`, `session_end`. You report facts; the sheep
supplies the snark, animations, and mood. Tools only affect what the sheep
displays — no filesystem or shell access.

Config lives in `~/.co-sheep/config.json`: `mcp_enabled` (default `true`),
`mcp_port` (default `4917`), `mcp_token` (optional bearer token; add
`--header "Authorization: Bearer <token>"` to the connect command if set).

### Getting Claude to actually narrate

The tools carry strong "when to call me" hints in their descriptions and the
server instructions — enough for Claude Code to pick the right one once it
decides to report. But whether it narrates *unprompted* is up to the agent, so
the reliable trigger is a line in your project's `CLAUDE.md`:

```markdown
When the co-sheep MCP server is connected, narrate your work through it:
`session_begin` when you start, `progress`/`set_task` as you go, and a
`milestone` when you finish, fail, or — especially — when you're `blocked` or
`waiting_on_you` and need me back at the screen.
```

That turns the sheep from "available" into "actually keeps you company."

## Ambient Effects

![Night mode](docs/night-mode.png)

- **Night mode** (8pm–6am) — twinkling stars, moonlight glow, fireflies near idle sheep, enhanced campfire glow
- **Weather** — set a city in settings and see rain or snow particles on screen; the AI references weather in commentary
- **Break reminders** — after 45 min of continuous work, the sheep nudges you to take a break (personality-flavored)

## Living Desktop

The flock runs a social simulation — drama emerges from real relationship data, not scripts:

- **Drama engine** — relationships move through `neutral → warm → inseparable` or `tension → feud → reconciling` based on affinity, moods, and jealousy (pet one sheep too much and the others notice). Feuding sheep refuse group activities, storm apart, and snipe at each other; a mutual friend eventually attempts mediation.
- **Spectacles** — rare desktop events (~at most one a day, guaranteed within three): a wolf scatters the flock, a UFO abducts someone, a traveling merchant gifts an accessory, a balloon drifts by, shearing day embarrasses everyone. Long feuds can erupt into a high-noon showdown; reconciliations end in a feast.
- **App awareness** — the sheep see which app is frontmost (name only, no extra permissions, no AI calls) and react: instant quips on app switches, gossip about your measured habits ("Hour 3 in the terminal. Blink twice if you need help."), and break reminders that name the culprit app.
- **Debug menu** — tray → Debug lets you summon any spectacle or force a feud on demand.

Drama state persists in `~/.co-sheep/drama.json`; spectacle timing in `~/.co-sheep/spectacles.json`.

## Animations

The AI picks an animation to match the mood of its commentary:

| Animation | Mood |
|-----------|------|
| bounce | excited, amused |
| spin | mind-blown |
| backflip | extreme excitement |
| headshake | disapproval |
| zoom | panic, urgency |
| vibrate | rage, frustration |

## Memory System

The sheep has a structured brain (`~/.co-sheep/opinions.json`):

- **Opinions** — beliefs about you with conviction scores that strengthen with repeated observation
- **Daily counters** — tracks recurring patterns within a day (auto-resets at midnight)
- **Interaction tracking** — remembers being petted, poked, and fed files
- **Daily diary** — raw timestamped observations at `~/.co-sheep/journal/`

The "Sheep's Brain" viewer (accessible from the menu) lets you inspect opinions, tallies, and diary entries.

## Settings

Accessible from the macOS menu bar or tray icon:

- **Sheep name** — rename your sheep anytime
- **Commentary interval** — 30 seconds to 10 minutes
- **Personality** — Snarky, Wholesome, Chaotic, or Passive-Aggressive
- **Language** — defaults to Nynorsk, with 10 language options
- **Weather location** — city name for weather awareness and effects
- **Summer Mode** — auto (June–August when the weather is clear and warm), always on, or off
- **Break reminders** — toggle 45-min work break nudges

Settings are stored at `~/.co-sheep/config.json`.

## Menu Actions

Available from the tray icon and macOS menu bar:

- **Settings** — configure sheep name, personality, interval, language, weather, seasons
- **Sheep's Brain** — view opinions, tallies, diary
- **Manage Friends** — add/remove friends, set personalities, accessories
- **Friend Relationships** — view affinity matrix and memories
- **Wardrobe** — dress up your main sheep with 18 accessories
- **Chat with Sheep** — direct conversation with the main sheep
- **Capture Moment** — save sheep screenshot to Desktop
- **Comment Now** — trigger immediate AI commentary

## Requirements

- macOS 27 on Apple Silicon, with Apple Intelligence enabled (the AI runs entirely on-device)
- Xcode 27 / Swift 6.4 toolchain to build

## Build & run

```bash
scripts/run.sh            # build (debug), bundle build/co-sheep.app, run with logs in the terminal
scripts/bundle.sh release # just assemble + sign build/co-sheep.app
scripts/build-dmg.sh      # release bundle → build/co-sheep_<version>_<arch>.dmg
swift test                # ~1000 tests (Swift Testing)
```

Dev knobs (environment variables):

| Variable | Effect |
|---|---|
| `CO_SHEEP_DEBUG=1` | verbose logs, incl. per-tile raster stats |
| `CO_SHEEP_HOME=/path` | use a scratch copy instead of `~/.co-sheep` |
| `CO_SHEEP_FPS=30` | overlay frame rate (default 60) |
| `CO_SHEEP_SNAPSHOT=/path.png` (+ `CO_SHEEP_SNAPSHOT_DELAY_MS`) | write a PNG of the overlay scene, no Screen Recording needed |

## Screen Recording Permission

co-sheep needs screen recording permission to see your screen. On first launch
macOS prompts you; grant it under **System Settings > Privacy & Security >
Screen Recording** and restart co-sheep.

Ad-hoc signed builds get a new signature every build, so macOS asks again after
each rebuild. Create a self-signed code-signing certificate named
`co-sheep dev` in Keychain Access and `scripts/bundle.sh` will use it
automatically (or set `CODESIGN_IDENTITY`).

## How it works

```
[configurable timer, default ~2.5 min, ±20%]
    |
    v
[ScreenCaptureKit: capture primary display, longest side ≤ 1568px]
    |
    v
[Vision OCR extracts on-screen text (on-device)]
    |
    v
[Pass 1: FoundationModels classifies the screen text]
    |
    +-- not interesting -> skip, log to diary
    |
    +-- interesting
         |
         v
       [Pass 2: FoundationModels generates comment + animation + opinion + count]
         |
         v
       [Speech bubble + animation on sheep]
       [Update opinions.json + daily journal]
```

Rendering: the flock's draw code uses a Canvas2D-shaped Swift API (`Canvas`)
that records display lists; each character/effect group is rasterized with
CoreGraphics into a small tile and composited by SpriteKit. Moving groups are
anchored, so pure motion just moves a node. Rain, snow and the night sky are
native SpriteKit particles.

## Project structure

```
co-sheep/
├── Package.swift                 # SwiftPM: CoSheep (app) + CoSheepKit (library) + tests
├── Sources/CoSheep/main.swift    # NSApplication bootstrap
├── Sources/CoSheepKit/
│   ├── App/        # AppDelegate, AppController (backend commands), menus, windows
│   ├── Overlay/    # transparent click-through panel, SpriteKit scene, input, chat bubble
│   ├── Render/     # Canvas API, display lists, CoreGraphics replay, tiles, sprites
│   ├── Sim/        # Sheep, Flock, bubbles, accessories, conversations, drama,
│   │               # spectacles, group activities, seasons, night, weather, managers
│   ├── Brain/      # config, opinions, journal, friend memory, reflection
│   ├── Services/   # FoundationModels + OCR, capture, weather, app watch, vision pipeline
│   ├── MCP/        # zero-dependency Streamable HTTP MCP server
│   ├── UI/         # SwiftUI windows: settings, brain, friends, wardrobe, naming, relationships
│   └── Resources/  # sprite sheets, icons
├── Tests/CoSheepKitTests/
└── scripts/        # bundle.sh, run.sh, build-dmg.sh
```

## Cost & privacy

Zero API cost — everything runs on Apple's on-device foundation model. Your
screen content never leaves your Mac: the sheep "sees" your screen through
on-device Vision OCR (extracted text) rather than the actual pixels. The MCP
server only listens on `127.0.0.1`.

## License

MIT
