export class SpriteSheet {
  private static imageCache: Map<string, HTMLImageElement> = new Map();
  private static tintCanvas: HTMLCanvasElement | null = null;
  private static tintCtx: CanvasRenderingContext2D | null = null;

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

    // Reuse cached image if available
    const cached = SpriteSheet.imageCache.get(src);
    if (cached) {
      this.image = cached;
      this.loaded = cached.complete && cached.naturalWidth > 0;
      if (!this.loaded) {
        cached.addEventListener("load", () => { this.loaded = true; }, { once: true });
      }
    } else {
      this.image = new Image();
      this.image.onload = () => {
        this.loaded = true;
      };
      this.image.onerror = () => {
        this.loaded = false;
      };
      this.image.src = src;
      SpriteSheet.imageCache.set(src, this.image);
    }
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
    tint?: string,
  ) {
    if (!this.loaded || !this.image) {
      // Fallback: draw a simple sheep shape
      this.drawFallback(ctx, x, y, scale);
      return;
    }

    const w = this.frameWidth * scale;
    const h = this.frameHeight * scale;
    const sx = this.currentFrame * this.frameWidth;

    if (tint) {
      // Use offscreen canvas so source-atop only affects the current sprite
      if (!SpriteSheet.tintCanvas) {
        SpriteSheet.tintCanvas = document.createElement("canvas");
        SpriteSheet.tintCtx = SpriteSheet.tintCanvas.getContext("2d")!;
      }
      const tc = SpriteSheet.tintCanvas;
      const tctx = SpriteSheet.tintCtx!;
      // Canvas dimensions are integers — compare against rounded sizes or a
      // fractional w/h reallocates (and stalls) on every single draw
      const cw = Math.ceil(w);
      const ch = Math.ceil(h);
      if (tc.width !== cw || tc.height !== ch) {
        tc.width = cw;
        tc.height = ch;
      } else {
        tctx.clearRect(0, 0, cw, ch);
      }

      tctx.imageSmoothingEnabled = false;
      tctx.globalCompositeOperation = "source-over";
      tctx.drawImage(
        this.image, sx, 0, this.frameWidth, this.frameHeight, 0, 0, w, h,
      );
      tctx.globalCompositeOperation = "source-atop";
      tctx.fillStyle = tint;
      tctx.fillRect(0, 0, w, h);

      ctx.save();
      if (flipX) {
        ctx.translate(x + w, y);
        ctx.scale(-1, 1);
      }
      ctx.drawImage(tc, flipX ? 0 : x, flipX ? 0 : y);
      ctx.restore();
    } else {
      ctx.save();
      if (flipX) {
        ctx.translate(x + w, y);
        ctx.scale(-1, 1);
        ctx.drawImage(this.image, sx, 0, this.frameWidth, this.frameHeight, 0, 0, w, h);
      } else {
        ctx.drawImage(this.image, sx, 0, this.frameWidth, this.frameHeight, x, y, w, h);
      }
      ctx.restore();
    }
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
