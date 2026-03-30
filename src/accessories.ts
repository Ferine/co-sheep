import { DrawOverlay } from "./sheep";
import { SheepState } from "./types";

export interface AccessoryDef {
  id: string;
  name: string;
  category: "head" | "face" | "neck";
  draw: DrawOverlay;
}

const ACCESSORIES: AccessoryDef[] = [
  {
    id: "party_hat",
    name: "Party Hat",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.15;

      ctx.save();
      // Red triangle hat
      ctx.fillStyle = "#e94560";
      ctx.beginPath();
      ctx.moveTo(headX - 4 * s, headY + 2 * s);
      ctx.lineTo(headX + 4 * s, headY + 2 * s);
      ctx.lineTo(headX, headY - 8 * s);
      ctx.closePath();
      ctx.fill();
      // Gold pom-pom
      ctx.fillStyle = "#FFD700";
      ctx.beginPath();
      ctx.arc(headX, headY - 8 * s, 2 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "crown",
    name: "Crown",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.2;

      ctx.save();
      // Gold zigzag band
      ctx.fillStyle = "#FFD700";
      ctx.beginPath();
      ctx.moveTo(headX - 5 * s, headY + 1 * s);
      ctx.lineTo(headX - 5 * s, headY - 3 * s);
      ctx.lineTo(headX - 2.5 * s, headY - 1 * s);
      ctx.lineTo(headX, headY - 4 * s);
      ctx.lineTo(headX + 2.5 * s, headY - 1 * s);
      ctx.lineTo(headX + 5 * s, headY - 3 * s);
      ctx.lineTo(headX + 5 * s, headY + 1 * s);
      ctx.closePath();
      ctx.fill();
      // Gem dots
      ctx.fillStyle = "#e94560";
      ctx.beginPath();
      ctx.arc(headX, headY - 2.5 * s, 1 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#4a90d9";
      ctx.beginPath();
      ctx.arc(headX - 3 * s, headY - 1.5 * s, 0.7 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(headX + 3 * s, headY - 1.5 * s, 0.7 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "sunglasses",
    name: "Sunglasses",
    category: "face",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.3;
      const glassY = headY + 2 * s;

      ctx.save();
      // Dark lenses
      ctx.fillStyle = "rgba(20, 20, 40, 0.85)";
      const lensW = 4 * s;
      const lensH = 2.5 * s;
      ctx.fillRect(headX - lensW - 1 * s, glassY - lensH / 2, lensW, lensH);
      ctx.fillRect(headX + 1 * s, glassY - lensH / 2, lensW, lensH);
      // Bridge
      ctx.strokeStyle = "#333";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(headX - 1 * s, glassY);
      ctx.lineTo(headX + 1 * s, glassY);
      ctx.stroke();
      // Frame
      ctx.strokeStyle = "#333";
      ctx.strokeRect(headX - lensW - 1 * s, glassY - lensH / 2, lensW, lensH);
      ctx.strokeRect(headX + 1 * s, glassY - lensH / 2, lensW, lensH);
      // Lens shine
      ctx.fillStyle = "rgba(255, 255, 255, 0.15)";
      ctx.fillRect(headX - lensW, glassY - lensH / 2 + 1, 2 * s, 1 * s);
      ctx.fillRect(headX + 1.5 * s, glassY - lensH / 2 + 1, 2 * s, 1 * s);
      ctx.restore();
    },
  },
  {
    id: "bow_tie",
    name: "Bow Tie",
    category: "neck",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const tieX = facingRight ? x + size * 0.48 : x + size * 0.42;
      const tieY = y + size * 0.55;

      ctx.save();
      ctx.fillStyle = "#9b59b6";
      // Left triangle
      ctx.beginPath();
      ctx.moveTo(tieX, tieY + 1.5 * s);
      ctx.lineTo(tieX - 4 * s, tieY);
      ctx.lineTo(tieX - 4 * s, tieY + 3 * s);
      ctx.closePath();
      ctx.fill();
      // Right triangle
      ctx.beginPath();
      ctx.moveTo(tieX, tieY + 1.5 * s);
      ctx.lineTo(tieX + 4 * s, tieY);
      ctx.lineTo(tieX + 4 * s, tieY + 3 * s);
      ctx.closePath();
      ctx.fill();
      // Center knot
      ctx.fillStyle = "#7d3c98";
      ctx.fillRect(tieX - 1 * s, tieY + 0.5 * s, 2 * s, 2 * s);
      ctx.restore();
    },
  },
  {
    id: "flower",
    name: "Flower",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.55 : x + size * 0.25;
      const headY = y + size * 0.2;

      ctx.save();
      // Petals
      ctx.fillStyle = "#ff69b4";
      for (let i = 0; i < 5; i++) {
        const angle = (i / 5) * Math.PI * 2;
        const px = headX + Math.cos(angle) * 3 * s;
        const py = headY + Math.sin(angle) * 3 * s;
        ctx.beginPath();
        ctx.arc(px, py, 2 * s, 0, Math.PI * 2);
        ctx.fill();
      }
      // Center
      ctx.fillStyle = "#FFD700";
      ctx.beginPath();
      ctx.arc(headX, headY, 1.5 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "scarf",
    name: "Scarf",
    category: "neck",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const neckX = x + size * 0.5;
      const neckY = y + size * 0.52;

      ctx.save();
      ctx.fillStyle = "#e94560";
      ctx.fillRect(neckX - 10 * s, neckY, 20 * s, 3 * s);
      ctx.fillStyle = "#c0392b";
      ctx.fillRect(neckX - 10 * s, neckY + 1 * s, 20 * s, 1 * s);
      const endX = facingRight ? neckX + 8 * s : neckX - 10 * s;
      ctx.fillStyle = "#e94560";
      ctx.fillRect(endX, neckY + 3 * s, 3 * s, 6 * s);
      ctx.fillStyle = "#c0392b";
      ctx.fillRect(endX, neckY + 4 * s, 3 * s, 1 * s);
      ctx.fillRect(endX, neckY + 7 * s, 3 * s, 1 * s);
      ctx.restore();
    },
  },
  {
    id: "top_hat",
    name: "Top Hat",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.18;

      ctx.save();
      // Brim
      ctx.fillStyle = "#1a1a2e";
      ctx.fillRect(headX - 6 * s, headY + 1 * s, 12 * s, 2 * s);
      // Cylinder
      ctx.fillStyle = "#2a2a3e";
      ctx.fillRect(headX - 4 * s, headY - 8 * s, 8 * s, 9 * s);
      // Band
      ctx.fillStyle = "#e94560";
      ctx.fillRect(headX - 4 * s, headY - 1 * s, 8 * s, 1.5 * s);
      // Top shine
      ctx.fillStyle = "rgba(255, 255, 255, 0.08)";
      ctx.fillRect(headX - 3 * s, headY - 7 * s, 3 * s, 6 * s);
      ctx.restore();
    },
  },
  {
    id: "halo",
    name: "Halo",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.12;

      ctx.save();
      // Glowing ring
      ctx.strokeStyle = "#FFD700";
      ctx.lineWidth = 2;
      ctx.shadowColor = "#FFD700";
      ctx.shadowBlur = 6;
      ctx.beginPath();
      ctx.ellipse(headX, headY, 5 * s, 1.5 * s, 0, 0, Math.PI * 2);
      ctx.stroke();
      // Second pass brighter
      ctx.shadowBlur = 0;
      ctx.strokeStyle = "rgba(255, 235, 100, 0.6)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.ellipse(headX, headY, 5 * s, 1.5 * s, 0, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    },
  },
  {
    id: "pirate_patch",
    name: "Eye Patch",
    category: "face",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.3;
      const eyeX = headX + (facingRight ? 2 : -2) * s;
      const eyeY = headY + 1 * s;

      ctx.save();
      // Strap
      ctx.strokeStyle = "#333";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(headX - 7 * s, headY - 2 * s);
      ctx.lineTo(headX + 7 * s, headY - 2 * s);
      ctx.stroke();
      // Patch
      ctx.fillStyle = "#1a1a1a";
      ctx.beginPath();
      ctx.ellipse(eyeX, eyeY, 3 * s, 2.5 * s, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = "#444";
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.restore();
    },
  },
  {
    id: "headphones",
    name: "Headphones",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.3;

      ctx.save();
      // Headband arc
      ctx.strokeStyle = "#555";
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      ctx.arc(headX, headY - 1 * s, 7 * s, Math.PI * 1.1, Math.PI * 1.9);
      ctx.stroke();
      // Left ear cup
      ctx.fillStyle = "#e94560";
      ctx.beginPath();
      ctx.ellipse(headX - 7 * s, headY + 1 * s, 2.5 * s, 3 * s, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#c0392b";
      ctx.beginPath();
      ctx.ellipse(headX - 7 * s, headY + 1 * s, 1.5 * s, 2 * s, 0, 0, Math.PI * 2);
      ctx.fill();
      // Right ear cup
      ctx.fillStyle = "#e94560";
      ctx.beginPath();
      ctx.ellipse(headX + 7 * s, headY + 1 * s, 2.5 * s, 3 * s, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#c0392b";
      ctx.beginPath();
      ctx.ellipse(headX + 7 * s, headY + 1 * s, 1.5 * s, 2 * s, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "monocle",
    name: "Monocle",
    category: "face",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.3;
      const eyeX = headX + (facingRight ? 2 : -2) * s;
      const eyeY = headY + 1.5 * s;

      ctx.save();
      // Lens
      ctx.strokeStyle = "#DAA520";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(eyeX, eyeY, 3.5 * s, 0, Math.PI * 2);
      ctx.stroke();
      // Lens shine
      ctx.fillStyle = "rgba(180, 220, 255, 0.15)";
      ctx.beginPath();
      ctx.arc(eyeX, eyeY, 3 * s, 0, Math.PI * 2);
      ctx.fill();
      // Chain hanging down
      ctx.strokeStyle = "#DAA520";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(eyeX, eyeY + 3.5 * s);
      ctx.quadraticCurveTo(
        eyeX + 2 * s,
        eyeY + 8 * s,
        eyeX - 1 * s,
        eyeY + 12 * s,
      );
      ctx.stroke();
      ctx.restore();
    },
  },
  {
    id: "wizard_hat",
    name: "Wizard Hat",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.18;

      ctx.save();
      // Brim
      ctx.fillStyle = "#2c3e80";
      ctx.beginPath();
      ctx.ellipse(headX, headY + 2 * s, 8 * s, 2 * s, 0, 0, Math.PI * 2);
      ctx.fill();
      // Cone
      ctx.fillStyle = "#3a4fa0";
      ctx.beginPath();
      ctx.moveTo(headX - 6 * s, headY + 2 * s);
      ctx.lineTo(headX + 6 * s, headY + 2 * s);
      ctx.lineTo(headX + 2 * s, headY - 12 * s);
      ctx.closePath();
      ctx.fill();
      // Stars on hat
      ctx.fillStyle = "#FFD700";
      ctx.font = `${3 * s}px serif`;
      ctx.fillText("\u2605", headX - 2 * s, headY - 3 * s);
      ctx.font = `${2 * s}px serif`;
      ctx.fillText("\u2605", headX + 2 * s, headY - 7 * s);
      // Tip curl
      ctx.strokeStyle = "#3a4fa0";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(headX + 4 * s, headY - 12 * s, 2 * s, Math.PI, Math.PI * 0.3, true);
      ctx.stroke();
      ctx.restore();
    },
  },
  {
    id: "bandana",
    name: "Bandana",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.25;

      ctx.save();
      // Headband
      ctx.fillStyle = "#e94560";
      ctx.fillRect(headX - 6 * s, headY, 12 * s, 2.5 * s);
      // Knot tails on the side
      const knotX = facingRight ? headX - 6 * s : headX + 6 * s;
      const knotDir = facingRight ? -1 : 1;
      ctx.fillStyle = "#c0392b";
      ctx.beginPath();
      ctx.moveTo(knotX, headY);
      ctx.lineTo(knotX + knotDir * 4 * s, headY - 2 * s);
      ctx.lineTo(knotX + knotDir * 1 * s, headY + 1 * s);
      ctx.closePath();
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(knotX, headY + 2.5 * s);
      ctx.lineTo(knotX + knotDir * 5 * s, headY + 3 * s);
      ctx.lineTo(knotX + knotDir * 1 * s, headY + 1.5 * s);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "mustache",
    name: "Mustache",
    category: "face",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.3;
      const mY = headY + 5 * s;

      ctx.save();
      ctx.fillStyle = "#3a2518";
      // Left curl
      ctx.beginPath();
      ctx.moveTo(headX, mY);
      ctx.quadraticCurveTo(headX - 3 * s, mY - 1.5 * s, headX - 5 * s, mY + 1 * s);
      ctx.quadraticCurveTo(headX - 3 * s, mY + 2 * s, headX, mY + 0.5 * s);
      ctx.closePath();
      ctx.fill();
      // Right curl
      ctx.beginPath();
      ctx.moveTo(headX, mY);
      ctx.quadraticCurveTo(headX + 3 * s, mY - 1.5 * s, headX + 5 * s, mY + 1 * s);
      ctx.quadraticCurveTo(headX + 3 * s, mY + 2 * s, headX, mY + 0.5 * s);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "cape",
    name: "Cape",
    category: "neck",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const neckX = x + size * 0.5;
      const neckY = y + size * 0.48;
      const dir = facingRight ? -1 : 1;

      ctx.save();
      // Cape body flowing behind
      ctx.fillStyle = "#8e1538";
      ctx.beginPath();
      ctx.moveTo(neckX + dir * 2 * s, neckY);
      ctx.lineTo(neckX + dir * 12 * s, neckY + 2 * s);
      ctx.quadraticCurveTo(
        neckX + dir * 14 * s,
        neckY + 12 * s,
        neckX + dir * 10 * s,
        neckY + 16 * s,
      );
      ctx.lineTo(neckX + dir * 3 * s, neckY + 14 * s);
      ctx.quadraticCurveTo(
        neckX + dir * 1 * s,
        neckY + 8 * s,
        neckX + dir * 2 * s,
        neckY,
      );
      ctx.closePath();
      ctx.fill();
      // Inner lining
      ctx.fillStyle = "#c0392b";
      ctx.beginPath();
      ctx.moveTo(neckX + dir * 3 * s, neckY + 2 * s);
      ctx.lineTo(neckX + dir * 10 * s, neckY + 3 * s);
      ctx.quadraticCurveTo(
        neckX + dir * 12 * s,
        neckY + 10 * s,
        neckX + dir * 9 * s,
        neckY + 14 * s,
      );
      ctx.lineTo(neckX + dir * 4 * s, neckY + 12 * s);
      ctx.closePath();
      ctx.fill();
      // Clasp
      ctx.fillStyle = "#FFD700";
      ctx.beginPath();
      ctx.arc(neckX + dir * 2 * s, neckY + 1 * s, 1.5 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "antenna",
    name: "Antenna",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.18;
      const t = Date.now() / 500;

      ctx.save();
      // Wire
      ctx.strokeStyle = "#666";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(headX, headY + 2 * s);
      ctx.quadraticCurveTo(headX + 1 * s, headY - 5 * s, headX - 1 * s, headY - 10 * s);
      ctx.stroke();
      // Bobble at top (bounces)
      const bobY = headY - 10 * s + Math.sin(t) * 1.5 * s;
      ctx.fillStyle = "#4ecca3";
      ctx.beginPath();
      ctx.arc(headX - 1 * s, bobY, 2.5 * s, 0, Math.PI * 2);
      ctx.fill();
      // Shine on bobble
      ctx.fillStyle = "rgba(255, 255, 255, 0.3)";
      ctx.beginPath();
      ctx.arc(headX - 1.5 * s, bobY - 1 * s, 1 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "chef_hat",
    name: "Chef Hat",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.18;

      ctx.save();
      // Base band
      ctx.fillStyle = "#f0f0f0";
      ctx.fillRect(headX - 5 * s, headY, 10 * s, 3 * s);
      // Puffy top — overlapping circles
      ctx.fillStyle = "#ffffff";
      ctx.beginPath();
      ctx.arc(headX - 3 * s, headY - 2 * s, 3.5 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(headX + 3 * s, headY - 2 * s, 3.5 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(headX, headY - 4 * s, 4 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(headX, headY - 1 * s, 3 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    },
  },
  {
    id: "necklace",
    name: "Necklace",
    category: "neck",
    draw: (ctx, x, y, size, _facingRight, _state) => {
      const s = size / 32;
      const cx = x + size * 0.5;
      const neckY = y + size * 0.55;

      ctx.save();
      // Chain
      ctx.strokeStyle = "#DAA520";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(cx, neckY - 2 * s, 8 * s, 0.15 * Math.PI, 0.85 * Math.PI);
      ctx.stroke();
      // Pendant
      ctx.fillStyle = "#4a90d9";
      ctx.beginPath();
      const pendantY = neckY - 2 * s + 8 * s * Math.sin(0.5 * Math.PI);
      ctx.moveTo(cx, pendantY);
      ctx.lineTo(cx - 2 * s, pendantY + 3 * s);
      ctx.lineTo(cx + 2 * s, pendantY + 3 * s);
      ctx.closePath();
      ctx.fill();
      // Gem shine
      ctx.fillStyle = "rgba(255, 255, 255, 0.3)";
      ctx.fillRect(cx - 0.5 * s, pendantY + 1 * s, 1 * s, 1 * s);
      ctx.restore();
    },
  },
  {
    id: "bunny_ears",
    name: "Bunny Ears",
    category: "head",
    draw: (ctx, x, y, size, facingRight, _state) => {
      const s = size / 32;
      const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
      const headY = y + size * 0.15;

      ctx.save();
      // Two ears splayed outward
      for (const side of [-1, 1]) {
        const earX = headX + side * 3.5 * s;
        const earTipY = headY - 12 * s;
        const earBaseY = headY;
        const earCX = earX + side * 1.5 * s;

        // Outer ear (white)
        ctx.fillStyle = "#FFFFFF";
        ctx.beginPath();
        ctx.ellipse(earCX, (earTipY + earBaseY) / 2, 2.5 * s, 6.5 * s, side * 0.15, 0, Math.PI * 2);
        ctx.fill();

        // Inner ear (pink)
        ctx.fillStyle = "#FFB6C1";
        ctx.beginPath();
        ctx.ellipse(earCX, (earTipY + earBaseY) / 2 + 0.5 * s, 1.5 * s, 5 * s, side * 0.15, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    },
  },
  {
    id: "easter_basket",
    name: "Easter Basket",
    category: "neck",
    draw: (ctx, x, y, size, facingRight, state) => {
      // Only show in calm states
      const calmStates = ["idle", "sit", "idle_sleep", "idle_campfire", "idle_counting", "idle_egg_painting", "sleep"];
      if (!calmStates.includes(state)) return;

      const s = size / 32;
      const bx = facingRight ? x + size * 0.85 : x - 4 * s;
      const by = y + size * 0.55;

      ctx.save();
      // Basket body (brown woven look)
      ctx.fillStyle = "#8B6914";
      ctx.beginPath();
      ctx.moveTo(bx - 4 * s, by);
      ctx.lineTo(bx + 4 * s, by);
      ctx.lineTo(bx + 3 * s, by + 5 * s);
      ctx.lineTo(bx - 3 * s, by + 5 * s);
      ctx.closePath();
      ctx.fill();

      // Weave lines
      ctx.strokeStyle = "#A0781E";
      ctx.lineWidth = 0.5 * s;
      ctx.beginPath();
      ctx.moveTo(bx - 3.5 * s, by + 2 * s);
      ctx.lineTo(bx + 3.5 * s, by + 2 * s);
      ctx.moveTo(bx - 3.2 * s, by + 3.5 * s);
      ctx.lineTo(bx + 3.2 * s, by + 3.5 * s);
      ctx.stroke();

      // Handle (arc)
      ctx.strokeStyle = "#8B6914";
      ctx.lineWidth = 1 * s;
      ctx.beginPath();
      ctx.arc(bx, by - 1 * s, 3.5 * s, Math.PI, 0);
      ctx.stroke();

      // Green grass
      ctx.fillStyle = "#7CFC00";
      for (let i = 0; i < 5; i++) {
        const gx = bx - 3 * s + i * 1.5 * s;
        ctx.fillRect(gx, by - 1 * s, 0.8 * s, 2 * s);
      }

      // Tiny eggs in basket
      const eggColors = ["#FFB6C1", "#B0E2AC", "#C8B4E6"];
      for (let i = 0; i < 3; i++) {
        ctx.fillStyle = eggColors[i];
        ctx.beginPath();
        ctx.ellipse(bx - 2 * s + i * 2 * s, by + 0.5 * s, 1 * s, 1.5 * s, 0, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    },
  },
];

export function getAccessoryDefs(): AccessoryDef[] {
  return ACCESSORIES;
}

/** Creates a composite DrawOverlay from a list of accessory IDs. Returns null if none selected. */
export function createCompositeOverlay(ids: string[]): DrawOverlay | null {
  if (ids.length === 0) return null;

  const selected = ACCESSORIES.filter((a) => ids.includes(a.id));
  if (selected.length === 0) return null;

  return (ctx: CanvasRenderingContext2D, x: number, y: number, size: number, facingRight: boolean, state: SheepState) => {
    for (const acc of selected) {
      acc.draw(ctx, x, y, size, facingRight, state);
    }
  };
}
