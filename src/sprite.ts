export class SpriteSheet {
  private image: HTMLImageElement | null = null;
  private loaded = false;
  private frameWidth: number;
  private frameHeight: number;
  private frameCount: number;
  private currentFrame = 0;
  private frameTimer = 0;
  private frameDuration: number;

  constructor(
    src: string,
    frameWidth: number,
    frameHeight: number,
    frameCount: number,
    fps: number = 4,
  ) {
    this.frameWidth = frameWidth;
    this.frameHeight = frameHeight;
    this.frameCount = frameCount;
    this.frameDuration = 1000 / fps;

    this.image = new Image();
    this.image.onload = () => {
      this.loaded = true;
    };
    this.image.onerror = () => {
      this.loaded = false;
    };
    this.image.src = src;
  }

  update(dt: number) {
    this.frameTimer += dt;
    if (this.frameTimer >= this.frameDuration) {
      this.frameTimer -= this.frameDuration;
      this.currentFrame = (this.currentFrame + 1) % this.frameCount;
    }
  }

  draw(
    ctx: CanvasRenderingContext2D,
    x: number,
    y: number,
    scale: number,
    flipX: boolean = false,
  ) {
    if (!this.loaded || !this.image) {
      // Fallback: draw a simple sheep shape
      this.drawFallback(ctx, x, y, scale);
      return;
    }

    ctx.save();
    if (flipX) {
      ctx.translate(x + this.frameWidth * scale, y);
      ctx.scale(-1, 1);
      ctx.drawImage(
        this.image,
        this.currentFrame * this.frameWidth,
        0,
        this.frameWidth,
        this.frameHeight,
        0,
        0,
        this.frameWidth * scale,
        this.frameHeight * scale,
      );
    } else {
      ctx.drawImage(
        this.image,
        this.currentFrame * this.frameWidth,
        0,
        this.frameWidth,
        this.frameHeight,
        x,
        y,
        this.frameWidth * scale,
        this.frameHeight * scale,
      );
    }
    ctx.restore();
  }

  private drawFallback(
    ctx: CanvasRenderingContext2D,
    x: number,
    y: number,
    scale: number,
  ) {
    const w = this.frameWidth * scale;
    const h = this.frameHeight * scale;

    ctx.save();

    // Body (fluffy white)
    ctx.fillStyle = "#f5f5f5";
    ctx.beginPath();
    ctx.ellipse(
      x + w * 0.5,
      y + h * 0.55,
      w * 0.35,
      h * 0.3,
      0,
      0,
      Math.PI * 2,
    );
    ctx.fill();
    ctx.strokeStyle = "#ccc";
    ctx.lineWidth = 2;
    ctx.stroke();

    // Head
    ctx.fillStyle = "#333";
    ctx.beginPath();
    ctx.ellipse(
      x + w * 0.72,
      y + h * 0.38,
      w * 0.14,
      h * 0.16,
      0,
      0,
      Math.PI * 2,
    );
    ctx.fill();

    // Eye
    ctx.fillStyle = "#fff";
    ctx.beginPath();
    ctx.arc(x + w * 0.76, y + h * 0.35, w * 0.04, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "#000";
    ctx.beginPath();
    ctx.arc(x + w * 0.77, y + h * 0.35, w * 0.02, 0, Math.PI * 2);
    ctx.fill();

    // Legs
    ctx.fillStyle = "#333";
    ctx.fillRect(x + w * 0.3, y + h * 0.78, w * 0.08, h * 0.2);
    ctx.fillRect(x + w * 0.45, y + h * 0.78, w * 0.08, h * 0.2);
    ctx.fillRect(x + w * 0.55, y + h * 0.78, w * 0.08, h * 0.2);
    ctx.fillRect(x + w * 0.65, y + h * 0.78, w * 0.08, h * 0.2);

    ctx.restore();
  }

  reset() {
    this.currentFrame = 0;
    this.frameTimer = 0;
  }
}
