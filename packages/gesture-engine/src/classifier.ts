// Gesture classification helpers: axis locking + tap/long-press discrimination.
// Pure functions and small enums so the recognizer FSM in index.ts stays readable
// and every decision boundary is independently testable.

/** Travel (px) a single-finger pan must accumulate before an axis is locked. */
export const AXIS_LOCK_TRAVEL_PX = 12;
/** Half-angle (deg) of the cone around an axis that counts as "locked to that axis". */
export const AXIS_LOCK_CONE_DEG = 22.5;

/** Max duration (ms) a touch may last and still count as a tap. */
export const TAP_MAX_DURATION_MS = 500;
/** Max movement (px) a touch may travel and still count as a tap. */
export const TAP_MAX_MOVE_PX = 8;
/** Max gap (ms) between two taps for a double-tap. */
export const DOUBLE_TAP_THRESHOLD_MS = 300;
/** Max distance (px) between two taps for a double-tap. */
export const DOUBLE_TAP_MAX_MOVE_PX = 30;

export type Axis = 'none' | 'vertical' | 'horizontal' | 'free';

export type GestureState =
  | 'idle'
  | 'undecided'
  | 'scrolling'
  | 'panning'
  | 'longpress-pending'
  | 'dragging'
  | 'pinching';

/**
 * Resolve the locked axis for a single-finger pan given total travel from the
 * touch origin. Returns 'none' until travel exceeds AXIS_LOCK_TRAVEL_PX, then
 * 'vertical' / 'horizontal' if within the cone, else 'free' (diagonal).
 */
export function resolveAxis(totalDx: number, totalDy: number): Axis {
  const dist = Math.hypot(totalDx, totalDy);
  if (dist < AXIS_LOCK_TRAVEL_PX) return 'none';
  // 0deg == horizontal (+x), 90deg == vertical. abs() folds all quadrants into [0,180].
  const angle = Math.abs((Math.atan2(totalDy, totalDx) * 180) / Math.PI);
  const cone = AXIS_LOCK_CONE_DEG;
  if (angle <= cone || angle >= 180 - cone) return 'horizontal';
  if (Math.abs(angle - 90) <= cone) return 'vertical';
  return 'free';
}

/** Project a delta onto a locked axis (zeroes the off-axis component). */
export function projectToAxis(dx: number, dy: number, axis: Axis): { dx: number; dy: number } {
  switch (axis) {
    case 'vertical':
      return { dx: 0, dy };
    case 'horizontal':
      return { dx, dy: 0 };
    default:
      return { dx, dy };
  }
}

export function isTap(durationMs: number, movePx: number): boolean {
  return durationMs < TAP_MAX_DURATION_MS && movePx < TAP_MAX_MOVE_PX;
}

export function isDoubleTap(gapMs: number, movePx: number): boolean {
  return gapMs < DOUBLE_TAP_THRESHOLD_MS && movePx < DOUBLE_TAP_MAX_MOVE_PX;
}
