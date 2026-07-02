import { invoke } from "@tauri-apps/api/core";

export interface InputBubbleConfig {
  promptText: string;
  placeholder: string;
  buttonText: string;
  onSubmit: (text: string) => Promise<void>;
  onClose?: () => void;
}

export class InputBubble {
  private element: HTMLDivElement;
  private input: HTMLInputElement;
  private button: HTMLButtonElement;
  private promptEl: HTMLDivElement;
  private config: InputBubbleConfig;

  constructor(config: InputBubbleConfig) {
    this.config = config;

    this.element = document.createElement("div");
    this.element.className = "speech-bubble input-bubble";
    this.element.style.display = "none";

    this.promptEl = document.createElement("div");
    this.promptEl.className = "speech-bubble-text";
    this.promptEl.textContent = config.promptText;
    this.element.appendChild(this.promptEl);

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
    this.hide();
    this.element.remove();
  }

  setLoading(on: boolean) {
    this.input.disabled = on;
    this.button.disabled = on;
    if (on) {
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
