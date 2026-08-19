import { describe, expect, it } from 'bun:test';
import {
  hostPathCrumbs,
  isThisPcPath,
  normalizeGoPath,
  parentHostPath,
} from '@/lib/host-path';

describe('parentHostPath', () => {
  it('walks Unix paths to root', () => {
    expect(parentHostPath('/home/obada/Projects')).toBe('/home/obada');
    expect(parentHostPath('/home')).toBe('/');
    expect(parentHostPath('/')).toBe('/');
  });

  it('walks Windows drives to This PC', () => {
    expect(parentHostPath('C:/Users/me')).toBe('C:/Users');
    expect(parentHostPath('C:/Users')).toBe('C:/');
    expect(parentHostPath('C:/')).toBe('/');
    expect(parentHostPath('D:/projects')).toBe('D:/');
  });
});

describe('normalizeGoPath', () => {
  it('does not force a leading slash onto drive paths', () => {
    expect(normalizeGoPath('D:/projects')).toBe('D:/projects');
    expect(normalizeGoPath('C:')).toBe('C:');
    expect(normalizeGoPath('home/foo')).toBe('/home/foo');
    expect(normalizeGoPath('/')).toBe('/');
  });
});

describe('hostPathCrumbs', () => {
  it('starts Windows crumbs at This PC', () => {
    const crumbs = hostPathCrumbs('D:/projects/foo');
    expect(crumbs[0]).toEqual({ label: 'This PC', path: '/' });
    expect(crumbs[1]).toEqual({ label: 'D:', path: 'D:/' });
    expect(crumbs.at(-1)?.path).toBe('D:/projects/foo');
  });

  it('treats slash as This PC', () => {
    expect(isThisPcPath('/')).toBe(true);
    expect(hostPathCrumbs('/')).toEqual([{ label: 'This PC', path: '/' }]);
  });
});
