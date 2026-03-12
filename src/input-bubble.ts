import { invoke } from "@tauri-apps/api/core";

export class InputBubble {
  private element: HTMLDivElement;
  private input: HTMLInputElement;
  private onSubmit: ((name: string) => void) | null = null;

  constructor() {
    this.element = document.createElement("div");
    this.element.className = "speech-bubble input-bubble";
    this.element.style.display = "none";

    const prompt = document.createElement("div");
    prompt.className = "speech-bubble-text";
    prompt.textContent =
      "Baaaa! I just landed on your desktop! What's my name?";
    this.element.appendChild(prompt);

    const form = document.createElement("form");
    form.className = "input-bubble-form";

    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.placeholder = "Name your sheep...";
    this.input.className = "input-bubble-input";
    form.appendChild(this.input);

    const button = document.createElement("button");
    button.type = "submit";
    button.textContent = "OK";
    button.className = "input-bubble-button";
    form.appendChild(button);

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const name = this.input.value.trim();
      if (name) {
        await invoke("save_sheep_name", { name });
        this.hide();
        if (this.onSubmit) this.onSubmit(name);
      }
    });

    this.element.appendChild(form);
    document.body.appendChild(this.element);
  }

  async show(onSubmit: (name: string) => void) {
    this.onSubmit = onSubmit;
    this.element.style.display = "block";

    // Disable click-through so user can type
    await invoke("set_cursor_events", { ignore: false });

    // Focus input
    setTimeout(() => this.input.focus(), 100);
  }

  async hide() {
    this.element.style.display = "none";

    // Re-enable click-through
    await invoke("set_cursor_events", { ignore: true });
  }

  updatePosition(sheepX: number, sheepY: number, sheepSize: number) {
    // Position above the sheep, centered horizontally
    const bubbleX = sheepX + sheepSize / 2;
    const bubbleY = sheepY - 20;

    this.element.style.left = `${bubbleX}px`;
    this.element.style.bottom = `${window.innerHeight - bubbleY}px`;
  }
}
