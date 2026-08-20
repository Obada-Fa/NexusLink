import { describe, it, expect } from 'bun:test';
import {
  ASPECT_TOL,
  cropToPhoneAspect,
  geometryClose,
  portraitTarget,
  aspectCorrectPlacement,
  streamRegionForAdopted,
} from '../phone-aspect';

describe('geometryClose', () => {
  it('accepts near matches', () => {
    expect(
      geometryClose({ x: 10, y: 20, width: 400, height: 800 }, { x: 12, y: 18, width: 405, height: 795 }, 32),
    ).toBe(true);
  });

  it('rejects large drifts', () => {
    expect(
      geometryClose({ x: 10, y: 20, width: 600, height: 800 }, { x: 10, y: 20, width: 400, height: 800 }, 32),
    ).toBe(false);
  });
});

describe('portraitTarget', () => {
  it('height-fits a phone aspect on a typical monitor', () => {
    const mon = { x: 0, y: 0, width: 1920, height: 1080 };
    const aspect = 390 / 844;
    const t = portraitTarget(mon, aspect);
    expect(t.height).toBe(1080 - 24 - 8);
    expect(t.width).toBe(Math.round(t.height * aspect));
    expect(t.x + t.width + 16).toBe(1920);
    expect(Math.abs(t.width / t.height - aspect)).toBeLessThan(0.01);
  });

  it('width-fits when the monitor is too narrow for height-fit', () => {
    const mon = { x: 0, y: 0, width: 400, height: 1200 };
    const aspect = 390 / 844;
    const t = portraitTarget(mon, aspect);
    expect(t.width).toBe(400 - 32);
    expect(t.height).toBe(Math.round(t.width / aspect));
  });
});

describe('aspectCorrectPlacement', () => {
  const mon = { x: 0, y: 0, width: 1920, height: 1080 };
  const aspect = 390 / 844;

  it('returns null when already close', () => {
    const h = 800;
    const w = Math.round(h * aspect);
    expect(
      aspectCorrectPlacement({ x: 100, y: 24, width: w, height: h }, aspect, mon),
    ).toBeNull();
  });

  it('shrinks height when the window is too wide', () => {
    // 600×800 is clearly wider than phone (~0.46); height 600/aspect ≈ 1298
    // exceeds the monitor, so this also exercises the width-fit clamp path —
    // use a narrower too-wide window that still fits vertically.
    const actual = { x: 100, y: 24, width: 450, height: 700 }; // aspect ~0.643
    const next = aspectCorrectPlacement(actual, aspect, mon);
    expect(next).not.toBeNull();
    // 450/aspect ≈ 974 < maxH(1048) → keep width, shrink height
    expect(next!.width).toBe(450);
    expect(next!.height).toBe(Math.round(450 / aspect));
    expect(Math.abs(next!.width / next!.height - aspect)).toBeLessThan(ASPECT_TOL);
  });

  it('width-fits when height-shrink would exceed the monitor', () => {
    const actual = { x: 100, y: 24, width: 700, height: 800 }; // needs h≈1515
    const next = aspectCorrectPlacement(actual, aspect, mon);
    expect(next).not.toBeNull();
    const maxH = mon.height - 24 - 8;
    expect(next!.height).toBe(maxH);
    expect(next!.width).toBe(Math.round(maxH * aspect));
    expect(Math.abs(next!.width / next!.height - aspect)).toBeLessThan(ASPECT_TOL);
  });
});

describe('cropToPhoneAspect', () => {
  const aspect = 390 / 844;

  it('center-crops a too-wide window', () => {
    const region = { x: 100, y: 50, width: 800, height: 800 };
    const cropped = cropToPhoneAspect(region, aspect);
    expect(cropped.height).toBe(800);
    expect(cropped.width).toBe(Math.round(800 * aspect) & ~1);
    expect(cropped.y).toBe(50);
    expect(cropped.x).toBeGreaterThan(100);
    expect(Math.abs(cropped.width / cropped.height - aspect)).toBeLessThan(0.02);
  });

  it('center-crops a too-tall window', () => {
    const region = { x: 10, y: 10, width: 400, height: 1200 };
    const cropped = cropToPhoneAspect(region, aspect);
    expect(cropped.width).toBe(400);
    expect(cropped.height).toBe(Math.round(400 / aspect) & ~1);
    expect(cropped.x).toBe(10);
    expect(cropped.y).toBeGreaterThan(10);
  });

  it('leaves a matching region alone (even-aligned)', () => {
    const h = 844;
    const w = Math.round(h * aspect) & ~1;
    const region = { x: 0, y: 0, width: w, height: h };
    const cropped = cropToPhoneAspect(region, aspect);
    expect(cropped.width).toBe(w & ~1);
    expect(cropped.height).toBe(h & ~1);
    expect(cropped.x).toBe(0);
    expect(cropped.y).toBe(0);
  });
});

describe('streamRegionForAdopted', () => {
  const aspect = 390 / 844;
  const screen = { width: 1920, height: 1080 };
  const target = { x: 1420, y: 24, width: 484, height: 1048 };

  it('keeps a small floating window as-is instead of a monitor slice', () => {
    const live = { x: 200, y: 100, width: 400, height: 300 };
    const region = streamRegionForAdopted(live, target, aspect, screen);
    expect(region).toEqual({ x: 200, y: 100, width: 400, height: 300 });
    expect(region.x).not.toBe(target.x);
    expect(region.width).toBeLessThan(target.width);
  });

  it('phone-aspect crops when the window landed on the placement target', () => {
    const live = { ...target };
    const region = streamRegionForAdopted(live, target, aspect, screen);
    expect(Math.abs(region.width / region.height - aspect)).toBeLessThan(0.05);
  });
});
