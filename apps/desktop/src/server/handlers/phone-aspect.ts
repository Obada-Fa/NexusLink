// Pure geometry helpers for phone-aspect window adoption / capture.
// Kept free of X11 so unit tests can lock the math.

import type { CaptureRegion } from '@nexuslink/rpc-types';

/** Relative aspect tolerance before we treat geometry as "close enough". */
export const ASPECT_TOL = 0.05;

/** True when |a-b| <= tol on every axis. */
export function geometryClose(
  actual: CaptureRegion,
  target: { x: number; y: number; width: number; height: number },
  tol = 32,
): boolean {
  return (
    Math.abs(actual.x - target.x) <= tol &&
    Math.abs(actual.y - target.y) <= tol &&
    Math.abs(actual.width - target.width) <= tol &&
    Math.abs(actual.height - target.height) <= tol
  );
}

/**
 * Center-crop (or letterbox-crop) a window rect so the returned capture region
 * matches `targetAspect` (width/height). Even-aligns dimensions for ffmpeg.
 *
 * - Window too wide → keep full height, crop left/right
 * - Window too tall → keep full width, crop top/bottom
 */
export function cropToPhoneAspect(
  region: CaptureRegion,
  targetAspect: number,
): CaptureRegion {
  if (region.width <= 0 || region.height <= 0 || !(targetAspect > 0)) {
    return {
      x: region.x,
      y: region.y,
      width: Math.max(0, region.width) & ~1,
      height: Math.max(0, region.height) & ~1,
    };
  }

  const got = region.width / region.height;
  let x = region.x;
  let y = region.y;
  let w = region.width;
  let h = region.height;

  if (got > targetAspect * (1 + ASPECT_TOL)) {
    w = Math.max(2, Math.round(region.height * targetAspect));
    x = region.x + Math.floor((region.width - w) / 2);
  } else if (got < targetAspect * (1 - ASPECT_TOL)) {
    h = Math.max(2, Math.round(region.width / targetAspect));
    y = region.y + Math.floor((region.height - h) / 2);
  }

  return {
    x,
    y,
    width: w & ~1,
    height: h & ~1,
  };
}

/**
 * Compute a portrait placement on the primary monitor that matches the phone
 * aspect. Height-fits first; if that would exceed the monitor width, width-fits.
 */
export function portraitTarget(
  mon: { x: number; y: number; width: number; height: number },
  targetAspect: number,
  marginTop = 24,
  marginBottom = 8,
  sidePad = 16,
): { x: number; y: number; width: number; height: number } {
  const maxH = Math.max(2, mon.height - marginTop - marginBottom);
  const maxW = Math.max(2, mon.width - sidePad * 2);
  let height = maxH;
  let width = Math.round(height * targetAspect);
  if (width > maxW) {
    width = maxW;
    height = Math.round(width / targetAspect);
  }
  width = Math.max(2, width);
  height = Math.max(2, height);
  const x = mon.x + mon.width - width - sidePad;
  const y = mon.y + marginTop;
  return { x, y, width, height };
}

/**
 * When the WM granted a window that is still too wide/tall for the phone
 * aspect, prefer shrinking the axis we can (usually height) so the live
 * window itself matches — capture then fills the phone with no letterbox.
 */
export function aspectCorrectPlacement(
  actual: CaptureRegion,
  targetAspect: number,
  mon: { x: number; y: number; width: number; height: number },
  marginTop = 24,
  marginBottom = 8,
  sidePad = 16,
): { x: number; y: number; width: number; height: number } | null {
  if (actual.width <= 0 || actual.height <= 0 || !(targetAspect > 0)) return null;
  const got = actual.width / actual.height;
  if (Math.abs(got - targetAspect) / targetAspect <= ASPECT_TOL) return null;

  const maxH = mon.height - marginTop - marginBottom;
  const maxW = mon.width - sidePad * 2;

  if (got > targetAspect) {
    // Too wide: prefer keeping width and shrinking height; if that exceeds the
    // monitor, width-fit instead so the result still matches phone aspect.
    let width = Math.min(maxW, actual.width);
    let height = Math.round(width / targetAspect);
    if (height > maxH) {
      height = maxH;
      width = Math.max(2, Math.round(height * targetAspect));
    }
    height = Math.max(2, Math.min(maxH, height));
    width = Math.max(2, Math.min(maxW, width));
    const x = mon.x + mon.width - width - sidePad;
    const y = mon.y + marginTop;
    return { x, y, width, height };
  }

  // Too tall: keep height, shrink width (and clamp).
  let height = Math.min(maxH, actual.height);
  let width = Math.round(height * targetAspect);
  if (width > maxW) {
    width = maxW;
    height = Math.max(2, Math.round(width / targetAspect));
  }
  height = Math.max(2, Math.min(maxH, height));
  width = Math.max(2, Math.min(maxW, width));
  const x = mon.x + mon.width - width - sidePad;
  const y = mon.y + marginTop;
  return { x, y, width, height };
}
