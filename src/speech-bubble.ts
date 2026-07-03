import { listen } from "@tauri-apps/api/event";
import { CommentaryEvent, SheepAnimation } from "./types";

export class SpeechBubble {
  private element: HTMLDivElement;
  private textElement: HTMLDivElement;
  private isVisible = false;
  private typewriterInterval: number | null = null;
  private hideTimeout: number | null = null;
  private unlisten: (() => void) | null = null;
  private lastText: string = "";

  /** Callback invoked when an animation should be triggered */
  onAnimation: ((anim: SheepAnimation) => void) | null = null;

  constructor(listenToCommentary: boolean = true, borderColor?: string) {
    this.element = document.createElement("div");
    this.element.className = "speech-bubble";
    this.element.style.display = "none";
    if (borderColor) {
      this.element.style.borderColor = borderColor;
      this.element.style.setProperty("--bubble-border-color", borderColor);
    }

    this.textElement = document.createElement("div");
    this.textElement.className = "speech-bubble-text";
    this.element.appendChild(this.textElement);

    document.body.appendChild(this.element);

    if (listenToCommentary) {
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
      }).then((fn) => {
        this.unlisten = fn;
      });
    }
  }

  get visible(): boolean {
    return this.isVisible;
  }

  get currentText(): string {
    return this.isVisible ? this.lastText : "";
  }

  show(text: string, duration: number = 5000) {
    this.clear();
    this.lastText = text;
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

    // Auto-hide after duration — but never before the 30ms/char typewriter
    // has finished, or long replies vanish mid-type
    const typewriterMs = text.length * 30;
    this.hideTimeout = window.setTimeout(() => {
      this.hide();
    }, Math.max(duration, typewriterMs + 2500));
  }

  hide() {
    this.clear();
    this.element.style.display = "none";
    this.isVisible = false;
  }

  /** Remove the DOM element when this bubble is no longer needed. */
  destroy() {
    this.clear();
    if (this.unlisten) {
      this.unlisten();
      this.unlisten = null;
    }
    this.element.remove();
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

    // Clamp to viewport edges so bubbles don't overflow — including the
    // top edge, or a sheep high on a window platform pushes the bubble
    // entirely off-screen
    const rect = this.element.getBoundingClientRect();
    const halfW = rect.width / 2;
    const clampedX = Math.max(halfW + 4, Math.min(bubbleX, window.innerWidth - halfW - 4));
    const clampedBottom = Math.min(
      Math.max(rect.height + 16, window.innerHeight - bubbleY),
      window.innerHeight - rect.height - 8,
    );

    this.element.style.left = `${clampedX}px`;
    this.element.style.bottom = `${clampedBottom}px`;
  }
}
