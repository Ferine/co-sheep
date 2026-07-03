import { invoke } from "@tauri-apps/api/core";

export interface InputBubbleConfig {
  promptText: string;
  placeholder: string;
  buttonText: string;
  onSubmit: (text: string) => Promise<void>;
  onClose?: () => void;
  /** Return true to keep the bubble open for this outside-mousedown (e.g. a sheep grab). */
  shouldIgnoreClickAway?: (e: MouseEvent) => boolean;
}

export class InputBubble {
  private element: HTMLDivElement;
  private input: HTMLInputElement;
  private button: HTMLButtonElement;
  private promptEl: HTMLDivElement;
  private replyEl: HTMLDivElement;
  private config: InputBubbleConfig;
  private onDocMousedown: (e: MouseEvent) => void;

  constructor(config: InputBubbleConfig) {
    this.config = config;

    this.element = document.createElement("div");
    this.element.className = "speech-bubble input-bubble";
    this.element.style.display = "none";

    this.promptEl = document.createElement("div");
    this.promptEl.className = "speech-bubble-text";
    this.promptEl.textContent = config.promptText;
    this.element.appendChild(this.promptEl);

    this.replyEl = document.createElement("div");
    this.replyEl.className = "speech-bubble-text input-bubble-reply";
    this.replyEl.style.display = "none";
    this.element.appendChild(this.replyEl);

    const form = document.createElement("form");
    form.className = "input-bubble-form";

    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.placeholder = config.placeholder;
    this.input.className = "input-bubble-input";
    form.appendChild(this.input);

    this.button = document.createElement("button");
    this.button.type = "submit";
    this.button.textContent = config.buttonText;
    this.button.className = "input-bubble-button";
    form.appendChild(this.button);

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const text = this.input.value.trim();
      if (text) {
        this.input.value = "";
        await this.config.onSubmit(text);
      }
    });

    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        this.config.onClose?.();
      }
    });

    this.element.appendChild(form);
    document.body.appendChild(this.element);

    // Click anywhere outside the bubble ends the conversation
    this.onDocMousedown = (e: MouseEvent) => {
      if (this.element.style.display === "none") return;
      if (this.element.contains(e.target as Node)) return;
      if (this.config.shouldIgnoreClickAway?.(e)) return;
      this.config.onClose?.();
    };
    document.addEventListener("mousedown", this.onDocMousedown);
  }

  /** Render the sheep's reply inside the bubble and hand the input back. */
  showReply(text: string, isError = false) {
    this.promptEl.style.display = "none";
    this.promptEl.classList.remove("input-bubble-loading");
    this.replyEl.style.display = "block";
    this.replyEl.style.opacity = "1";
    this.replyEl.textContent = text;
    this.replyEl.classList.toggle("input-bubble-reply-error", isError);
    this.input.disabled = false;
    this.button.disabled = false;
    this.input.focus();
  }

  show() {
    this.element.style.display = "block";
    invoke("set_cursor_events", { ignore: false });
    setTimeout(() => this.input.focus(), 100);
  }

  hide() {
    this.element.style.display = "none";
    invoke("set_cursor_events", { ignore: true });
  }

  destroy() {
    document.removeEventListener("mousedown", this.onDocMousedown);
    this.hide();
    this.element.remove();
  }

  setLoading(on: boolean) {
    this.input.disabled = on;
    this.button.disabled = on;
    // The previous reply stays visible (it's the conversation context) but
    // dims while the next one is being thought up
    this.replyEl.style.opacity = on ? "0.5" : "1";
    if (on) {
      // showReply hides the prompt line — bring it back for "thinking..."
      this.promptEl.style.display = "block";
      this.promptEl.textContent = "thinking...";
      this.promptEl.classList.add("input-bubble-loading");
    } else {
      this.promptEl.textContent = this.config.promptText;
      this.promptEl.classList.remove("input-bubble-loading");
    }
  }

  updatePosition(sheepX: number, sheepY: number, sheepSize: number) {
    const bubbleX = sheepX + sheepSize / 2;
    const bubbleY = sheepY - 20;

    const rect = this.element.getBoundingClientRect();
    const halfW = rect.width / 2;
    const clampedX = Math.max(halfW + 4, Math.min(bubbleX, window.innerWidth - halfW - 4));
    // Clamp against the top edge too — the chat input must stay visible
    // even when the sheep is high up on a window platform
    const clampedBottom = Math.min(
      Math.max(rect.height + 16, window.innerHeight - bubbleY),
      window.innerHeight - rect.height - 8,
    );

    this.element.style.left = `${clampedX}px`;
    this.element.style.bottom = `${clampedBottom}px`;
  }
}
