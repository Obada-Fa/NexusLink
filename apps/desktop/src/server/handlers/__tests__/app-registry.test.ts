import { describe, expect, test } from 'bun:test';
import { listRegistryApps, getRegistryApp } from '../app-registry';
import { ideStatus } from '../ide';
import { listProjects } from '../fs';

describe('app registry', () => {
  test('declares the four plan tiers', () => {
    const apps = listRegistryApps();
    expect(apps.map((a) => a.appId)).toContain('nexus.chrome-mobile');
    expect(apps.map((a) => a.appId)).toContain('nexus.vscode');
    expect(apps.map((a) => a.appId)).toContain('nexus.terminal');
    expect(apps.map((a) => a.appId)).toContain('nexus.agents');
    expect(getRegistryApp('nexus.chrome-mobile')?.tier).toBe(1);
    expect(getRegistryApp('nexus.vscode')?.tier).toBe(3);
    expect(getRegistryApp('nexus.agents')?.tier).toBe(4);
  });
});

describe('ide (code-server)', () => {
  test('reports availability without throwing', () => {
    const st = ideStatus();
    expect(typeof st.available).toBe('boolean');
    if (!st.available) expect(st.reason).toContain('code-server');
  });
});

describe('listProjects', () => {
  test('returns an array of {name, path}', async () => {
    const projects = await listProjects();
    expect(Array.isArray(projects)).toBe(true);
    for (const p of projects) {
      expect(p.name.length).toBeGreaterThan(0);
      expect(p.path.startsWith('/')).toBe(true);
    }
  });
});
