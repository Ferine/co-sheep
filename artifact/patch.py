#!/usr/bin/env python3
"""Patch the legacy TypeScript sim (extracted from git history) for the
browser artifact. Each patch must apply exactly once, or the build fails."""
import base64, pathlib, sys

legacy = pathlib.Path(sys.argv[1])        # .build/legacy/src
sprites = pathlib.Path(sys.argv[2])       # Sources/CoSheepKit/Resources/sprites


def patch(name, old, new, count=1):
    p = legacy / name
    text = p.read_text()
    found = text.count(old)
    if found != count:
        sys.exit(f"patch {name}: expected {count} match(es), found {found}: {old[:60]!r}")
    p.write_text(text.replace(old, new))


# Sprites ship inline as data URLs.
lines = ["export const SPRITE_URLS: Record<string, string> = {"]
for png in sorted(sprites.glob("sheep-*.png")):
    key = png.stem.removeprefix("sheep-")
    data = base64.b64encode(png.read_bytes()).decode()
    lines.append(f'  "{key}": "data:image/png;base64,{data}",')
lines.append("};")
(legacy / "sprite-data.ts").write_text("\n".join(lines) + "\n")

patch("sheep.ts", 'import { SpriteSheet } from "./sprite";',
      'import { SpriteSheet } from "./sprite";\nimport { SPRITE_URLS } from "./sprite-data";')
for key in ["idle", "walk", "parachute", "sit", "sleep", "fall"]:
    patch("sheep.ts", f'"/assets/sprites/sheep-{key}.png"', f'SPRITE_URLS["{key}"]')

# The desktop overlay covers the display's work area (the Dock is already
# outside it), so the ground margin has to be settable.
patch("sheep.ts", "const DOCK_MARGIN = 80; // stay above macOS Dock",
      "let DOCK_MARGIN = 80; // stay above macOS Dock\n"
      "export function setDockMargin(px: number) { DOCK_MARGIN = px; }")

# Friend-to-friend AI chat ran on a timer against the on-device model. An
# artifact may only ask Claude on an explicit action, so these stay scripted.
patch("flock.ts", "&& Math.random() < 0.3) {\n          this.startAIConversation",
      "&& AI_FRIEND_CHAT && Math.random() < 0.3) {\n          this.startAIConversation")
patch("flock.ts", "export class Flock {", "const AI_FRIEND_CHAT = false;\n\nexport class Flock {")

# The overlay window is click-through, so a click elsewhere never reaches the
# page: the chat bubble needs its own close button (the Swift app has one too).
patch("input-bubble.ts", "    this.element.appendChild(form);\n",
      "    this.element.appendChild(form);\n\n"
      "    const close = document.createElement(\"button\");\n"
      "    close.type = \"button\";\n"
      "    close.className = \"input-bubble-close\";\n"
      "    close.setAttribute(\"aria-label\", \"Close chat\");\n"
      "    close.textContent = \"\\u00d7\";\n"
      "    close.addEventListener(\"click\", () => this.config.onClose?.());\n"
      "    this.element.appendChild(close);\n")
print("patched", legacy)
