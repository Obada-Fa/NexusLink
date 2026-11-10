import { afterEach, beforeEach, expect, it } from 'bun:test';
import { mirrorUrl, readMirrorTarget } from '@/lib/mirror-target';

const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'sessionStorage');
let search = '';
let replaced = '';
let saved: Map<string, string>;

beforeEach(() => {
  saved = new Map();
  search = '';
  replaced = '';
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: {
    getItem: (key: string) => saved.get(key) ?? null,
    setItem: (key: string, value: string) => saved.set(key, value),
  } });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: {
    location: { get search() { return search; } },
    history: { state: { router: true }, replaceState: (_state: unknown, _title: string, url: string) => { replaced = url; } },
  } });
});

afterEach(() => {
  if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow);
  else Reflect.deleteProperty(globalThis, 'window');
  if (previousStorage) Object.defineProperty(globalThis, 'sessionStorage', previousStorage);
  else Reflect.deleteProperty(globalThis, 'sessionStorage');
});

it('opens apps and sessions without exposing titles, IDs or window classes', () => {
  for (const target of [
    { appId: 'claude.desktop', wmClass: 'Claude', title: 'Private Claude chat' },
    { virtualAppId: 'nexus.claude', title: 'Claude' },
    { sessionId: 'private-session', title: 'Claude' },
    { windowId: '12345', title: 'Claude' },
  ]) {
    const url = mirrorUrl(target);
    expect(url).toMatch(/^\/mirror\?view=[a-f0-9]{32}$/);
    search = url.slice(url.indexOf('?'));
    expect(readMirrorTarget()).toEqual(target);
  }
});

it('restores a target from tab storage after reloading', () => {
  saved.set('nexuslink-mirror:reload', JSON.stringify({ sessionId: 's1', title: 'Claude' }));
  search = '?view=reload';
  expect(readMirrorTarget()).toEqual({ sessionId: 's1', title: 'Claude' });
});

it('removes identity from an old link and retains its target', () => {
  search = '?app=claude.desktop&title=Claude&cls=Claude';
  expect(readMirrorTarget()).toMatchObject({ appId: 'claude.desktop', title: 'Claude', wmClass: 'Claude' });
  expect(replaced).toMatch(/^\/mirror\?view=[a-f0-9]{32}$/);
});

it('fails closed for a missing view instead of streaming the full desktop', () => {
  search = '?view=missing';
  expect(() => readMirrorTarget()).toThrow('no longer available');
  search = '';
  expect(readMirrorTarget()).toEqual({});
});
