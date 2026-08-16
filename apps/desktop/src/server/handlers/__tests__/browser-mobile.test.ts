import { describe, it, expect } from 'bun:test';
import {
  MOBILE_UA,
  buildMobileEmulationCommands,
  isBraveAppId,
  isBraveWmClass,
  resolveBraveBinary,
} from '../browser-mobile';

describe('Brave detection', () => {
  it('matches common WM_CLASS forms', () => {
    expect(isBraveWmClass('brave-browser.Brave-browser')).toBe(true);
    expect(isBraveWmClass('Brave-browser.Brave-browser')).toBe(true);
    expect(isBraveWmClass('navigator.firefox')).toBe(false);
    expect(isBraveWmClass(null)).toBe(false);
  });

  it('matches desktop app ids', () => {
    expect(isBraveAppId('brave-browser')).toBe(true);
    expect(isBraveAppId('com.brave.Browser')).toBe(true);
    expect(isBraveAppId('org.gnome.Calculator')).toBe(false);
  });
});

describe('buildMobileEmulationCommands', () => {
  it('emits UA, touch, and device-metrics overrides', () => {
    const cmds = buildMobileEmulationCommands({ width: 390, height: 700, dpr: 2.75 });
    const methods = cmds.map((c) => (c as { method: string }).method);
    expect(methods).toContain('Emulation.setUserAgentOverride');
    expect(methods).toContain('Emulation.setTouchEmulationEnabled');
    expect(methods).toContain('Emulation.setDeviceMetricsOverride');
    expect(methods).toContain('Emulation.setEmitTouchEventsForMouse');

    const ua = cmds.find(
      (c) => (c as { method: string }).method === 'Emulation.setUserAgentOverride',
    ) as { params: { userAgent: string; userAgentMetadata: { mobile: boolean } } };
    expect(ua.params.userAgent).toBe(MOBILE_UA);
    expect(ua.params.userAgentMetadata.mobile).toBe(true);

    const metrics = cmds.find(
      (c) => (c as { method: string }).method === 'Emulation.setDeviceMetricsOverride',
    ) as {
      params: {
        width: number;
        height: number;
        deviceScaleFactor: number;
        mobile: boolean;
        dontSetVisibleSize: boolean;
      };
    };
    expect(metrics.params.width).toBe(390);
    expect(metrics.params.height).toBe(700);
    expect(metrics.params.deviceScaleFactor).toBe(2.75);
    expect(metrics.params.mobile).toBe(true);
    expect(metrics.params.dontSetVisibleSize).toBe(true);
  });

  it('clamps tiny viewports to a usable phone minimum', () => {
    const metrics = buildMobileEmulationCommands({ width: 10, height: 10 }).find(
      (c) => (c as { method: string }).method === 'Emulation.setDeviceMetricsOverride',
    ) as { params: { width: number; height: number } };
    expect(metrics.params.width).toBeGreaterThanOrEqual(320);
    expect(metrics.params.height).toBeGreaterThanOrEqual(480);
  });
});

describe('resolveBraveBinary', () => {
  it('returns a string path or null without throwing', () => {
    const bin = resolveBraveBinary();
    expect(bin === null || typeof bin === 'string').toBe(true);
    // This environment has Chrome as a Chromium stand-in.
    if (bin) expect(bin.length).toBeGreaterThan(0);
  });
});
