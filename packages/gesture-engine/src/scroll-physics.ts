// Scroll physics: velocity estimation + momentum (inertia) integration.
// Pure, dependency-free math so it is deterministically unit-testable.

/** Deceleration constant (s^-1). ~300ms time constant, iOS-"normal"-like feel. */
export const SCROLL_INERTIA_LAMBDA = 3.3;
/** Minimum release speed (host px/s) required to start an inertia fling. */
export const SCROLL_INERTIA_MIN_VELOCITY = 250;
/** Speed (host px/s) at which an inertia fling is considered stopped. */
export const SCROLL_INERTIA_STOP_VELOCITY = 4;
/** EMA smoothing factor for the velocity estimator (weight of the newest sample). */
export const VELOCITY_EMA_ALPHA = 0.4;
/** Minimum sample interval (ms). Guards against divide-by-zero / spikes on fast events. */
export const MIN_SAMPLE_DT_MS = 4;

/** Remaining velocity after `dtSeconds` of exponential decay from `v0`. */
export function decayVelocity(v0: number, dtSeconds: number, lambda = SCROLL_INERTIA_LAMBDA): number {
  return v0 * Math.exp(-lambda * dtSeconds);
}

/**
 * Closed-form displacement of an exponentially-decaying fling between two times
 * (seconds since release): ∫ v0·e^(−λt) dt from t0 to t1 = (v0/λ)·(e^(−λt0) − e^(−λt1)).
 */
export function inertiaDisplacement(
  v0: number,
  t0: number,
  t1: number,
  lambda = SCROLL_INERTIA_LAMBDA,
): number {
  return (v0 / lambda) * (Math.exp(-lambda * t0) - Math.exp(-lambda * t1));
}

/** Total distance a fling of initial velocity `v0` will ever travel (t→∞). */
export function inertiaTotalDistance(v0: number, lambda = SCROLL_INERTIA_LAMBDA): number {
  return v0 / lambda;
}

/**
 * Exponential-moving-average velocity estimator over per-move deltas.
 * Feed it host-space deltas + timestamps; read `.velocity` at release time.
 */
export class ScrollVelocityTracker {
  private vx = 0;
  private vy = 0;
  private lastT = 0;
  private primed = false;

  reset(): void {
    this.vx = 0;
    this.vy = 0;
    this.lastT = 0;
    this.primed = false;
  }

  /** @param dx,dy delta since the previous sample (host px). @param tMs sample timestamp. */
  addSample(dx: number, dy: number, tMs: number): void {
    if (!this.primed) {
      this.lastT = tMs;
      this.primed = true;
      return;
    }
    const dtMs = Math.max(MIN_SAMPLE_DT_MS, tMs - this.lastT);
    this.lastT = tMs;
    const dtSec = dtMs / 1000;
    const instVx = dx / dtSec;
    const instVy = dy / dtSec;
    this.vx = VELOCITY_EMA_ALPHA * instVx + (1 - VELOCITY_EMA_ALPHA) * this.vx;
    this.vy = VELOCITY_EMA_ALPHA * instVy + (1 - VELOCITY_EMA_ALPHA) * this.vy;
  }

  get velocity(): { vx: number; vy: number } {
    return { vx: this.vx, vy: this.vy };
  }

  get speed(): number {
    return Math.hypot(this.vx, this.vy);
  }
}
