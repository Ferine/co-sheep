import { listen } from "@tauri-apps/api/event";
import { CommentaryEvent, SheepAnimation } from "./types";

export class SpeechBubble {
  private element: HTMLDivElement;
  private textElement: HTMLDivElement;
  private isVisible = false;
  private typewriterInterval: number | null = null;
  private hideTimeout: number | null = null;

  /** Callback invoked when an animation should be triggered */
  onAnimation: ((anim: SheepAnimation) => void) | null = null;

  constructor() {
    this.element = document.createElement("div");
    this.element.className = "speech-bubble";
    this.element.style.display = "none";

    this.textElement = document.createElement("div");
    this.textElement.className = "speech-bubble-text";
    this.element.appendChild(this.textElement);

    document.body.appendChild(this.element);

    // Listen for structured commentary events from Rust backend
    listen<CommentaryEvent | string>("sheep-commentary", (event) => {
      const payload = event.payload;

      if (typeof payload === "string") {
        // Legacy plain string (from permission/error messages)
        console.log("[co-sheep] Speech bubble (plain):", payload);
        this.show(payload, 8000);
      } else {
        // Structured event with text + animation
        console.log(
          "[co-sheep] Speech bubble:",
          payload.text,
          "animation:",
          payload.animation,
        );
        this.show(payload.text, 8000);
        if (payload.animation && this.onAnimation) {
          this.onAnimation(payload.animation);
        }
      }
    });
  }

  show(text: string, duration: number = 5000) {
    this.clear();
    this.element.style.display = "block";
    this.isVisible = true;
    this.textElement.textContent = "";

    // Typewriter effect
    let i = 0;
    this.typewriterInterval = window.setInterval(() => {
      if (i < text.length) {
        this.textElement.textContent += text[i];
        i++;
      } else {
        if (this.typewriterInterval) {
          clearInterval(this.typewriterInterval);
          this.typewriterInterval = null;
        }
      }
    }, 30);

    // Auto-hide after duration
    this.hideTimeout = window.setTimeout(() => {
      this.hide();
    }, duration);
  }

  hide() {
    this.clear();
    this.element.style.display = "none";
    this.isVisible = false;
  }

  private clear() {
    if (this.typewriterInterval) {
      clearInterval(this.typewriterInterval);
      this.typewriterInterval = null;
    }
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout);
      this.hideTimeout = null;
    }
  }

  updatePosition(sheepX: number, sheepY: number, sheepSize: number) {
    if (!this.isVisible) return;

    // Position above the sheep, centered horizontally
    const bubbleX = sheepX + sheepSize / 2;
    const bubbleY = sheepY - 20;

    this.element.style.left = `${bubbleX}px`;
    this.element.style.bottom = `${window.innerHeight - bubbleY}px`;
  }
}
