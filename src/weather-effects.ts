interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
}

export class WeatherEffects {
  private particles: Particle[] = [];
  private _condition: string | null = null;

  get condition(): string | null {
    return this._condition;
  }

  setCondition(c: string | null) {
    if (c === this._condition) return;
    this._condition = c;
    this.particles = [];
  }

  update(dt: number, screenW: number, screenH: number) {
    if (!this._condition || this._condition === "clear" || this._condition === "cloudy") return;

    const dtSec = dt / 1000;

    if (this._condition === "rain") {
      // Spawn rain particles
      while (this.particles.length < 50) {
        this.particles.push({
          x: Math.random() * screenW,
          y: -10 - Math.random() * 50,
          vx: -20 + Math.random() * 10, // slight wind
          vy: 300 + Math.random() * 200,
          life: Math.random() * Math.PI * 2,
        });
      }
    } else if (this._condition === "snow") {
      while (this.particles.length < 30) {
        this.particles.push({
          x: Math.random() * screenW,
          y: -10 - Math.random() * 30,
          vx: 0,
          vy: 20 + Math.random() * 40,
          // Random phase so flakes get distinct sway and twinkle
          life: Math.random() * Math.PI * 2,
        });
      }
    }

    // Update particles
    this.particles = this.particles.filter((p) => {
      p.x += p.vx * dtSec;
      p.y += p.vy * dtSec;
      p.life += dtSec; // drives per-particle sway phase and twinkle

      // Snow: horizontal sine drift
      if (this._condition === "snow") {
        p.vx = Math.sin(p.y / 60 + p.life * 10) * 15;
      }

      // Recycle particles that exit the bottom
      if (p.y > screenH + 10) {
        p.y = -10;
        p.x = Math.random() * screenW;
        return true;
      }
      if (p.x < -20 || p.x > screenW + 20) {
        p.x = Math.random() * screenW;
        p.y = -10;
      }
      return true;
    });
  }

  draw(ctx: CanvasRenderingContext2D) {
    if (!this._condition || this.particles.length === 0) return;

    ctx.save();

    if (this._condition === "rain") {
      ctx.strokeStyle = "rgba(130, 170, 255, 0.4)";
      ctx.lineWidth = 1;
      for (const p of this.particles) {
        ctx.beginPath();
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(p.x + p.vx * 0.01, p.y + 6);
        ctx.stroke();
      }
    } else if (this._condition === "snow") {
      ctx.fillStyle = "rgba(255, 255, 255, 0.7)";
      for (const p of this.particles) {
        const size = 1.5 + Math.sin(p.life * 5) * 0.5;
        ctx.beginPath();
        ctx.arc(p.x, p.y, size, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    ctx.restore();
  }
}
