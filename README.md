# co-sheep

A desktop companion sheep that watches your screen and delivers snarky commentary. Think unhinged Clippy meets a judgmental pixel art sheep.

![Tauri](https://img.shields.io/badge/Tauri-v2-blue) ![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

## What it does

- A pixel sheep parachutes onto your desktop and wanders around
- Every few minutes, it captures your screen and sends it through a two-pass AI vision pipeline
- **Pass 1** (Haiku): cheap classification — is anything interesting happening?
- **Pass 2** (Sonnet): snarky commentary with expressive animations — only when warranted
- The sheep keeps a markdown diary of its observations at `~/.co-sheep/journal/`
- You can drag and drop the sheep — it wiggles when grabbed and deploys a parachute if dropped mid-air

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

## Requirements

- macOS (uses CoreGraphics for cursor tracking and screen capture)
- [Node.js](https://nodejs.org/) (v18+)
- [Rust](https://rustup.rs/) (stable)
- An [Anthropic API key](https://console.anthropic.com/)

## Setup

```bash
# Install dependencies
npm install

# Set your API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Run in development
npm run tauri dev

# Build for production
npm run tauri build
```

The `.app` bundle will be at `src-tauri/target/release/bundle/macos/co-sheep.app`.

## Screen Recording Permission

co-sheep needs screen recording permission to see your screen. On first launch:

1. macOS will prompt you to grant permission
2. Go to **System Settings > Privacy & Security > Screen Recording**
3. Add the co-sheep binary or `.app` bundle
4. Restart co-sheep

## How it works

```
[~2-3 min timer]
    |
    v
[xcap: capture screen -> resize 1568px -> JPEG q70 -> base64]
    |
    v
[Pass 1: Haiku classifies screenshot]
    |
    +-- not interesting -> skip
    |
    +-- interesting
         |
         v
       [Pass 2: Sonnet generates snarky comment + animation]
         |
         v
       [Speech bubble + animation on the sheep]
```

## Project structure

```
co-sheep/
├── src/                    # TypeScript frontend
│   ├── main.ts             # Canvas loop, drag-and-drop, event wiring
│   ├── sheep.ts            # State machine, physics, animations
│   ├── sprite.ts           # Sprite sheet loader and animator
│   ├── speech-bubble.ts    # DOM speech bubble with typewriter effect
│   └── types.ts            # Shared types
├── src-tauri/src/           # Rust backend
│   ├── lib.rs              # App builder, tray, commands
│   ├── vision.rs           # Two-pass AI vision pipeline
│   ├── capture.rs          # Screen capture via xcap
│   ├── personality.rs      # Sheep persona system prompt
│   ├── memory.rs           # Markdown journal system
│   ├── cursor.rs           # CoreGraphics cursor tracking
│   ├── onboarding.rs       # First-launch naming flow
│   └── permissions.rs      # macOS screen recording permission
└── public/
    ├── naming.html         # Naming dialog window
    └── assets/sprites/     # Pixel art sprite sheets
```

## Cost

At 2-3 minute intervals running all day: roughly $1-3/day in API costs. Haiku classification keeps costs low by only invoking Sonnet when something interesting is on screen.

## License

MIT
