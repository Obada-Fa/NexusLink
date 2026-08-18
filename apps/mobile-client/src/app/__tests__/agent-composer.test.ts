import { describe, expect, it } from 'bun:test';
import {
  applyComposerPrefs,
  fallbackCaps,
  modeLabel,
  modelLabel,
  resolveAgentCaps,
  thinkingLabel,
  workingTreeSubtitle,
} from '@/lib/agent-composer';

describe('composer caps for every agent', () => {
  it('gives Claude, OpenCode, Antigravity, and Cursor plan + thinking + models', () => {
    for (const id of ['cursor', 'claude', 'opencode', 'antigravity', 'mock'] as const) {
      const caps = fallbackCaps(id);
      expect(caps.modes.length).toBeGreaterThan(1);
      expect(caps.modes).toContain('plan');
      expect(caps.thinkingLevels.length).toBeGreaterThan(1);
      expect(caps.models.length).toBeGreaterThan(0);
      expect(caps.images).toBe(true);
    }
  });

  it('prefers live models and host modes when the PC sends them', () => {
    const caps = resolveAgentCaps(
      'claude',
      { modes: ['agent'], thinkingLevels: [], models: [{ id: 'sonnet', name: 'Sonnet' }] },
      [{ id: 'opus', name: 'Opus' }],
    );
    expect(caps.modes).toContain('plan');
    expect(caps.thinkingLevels).toContain('high');
    expect(caps.models[0]?.id).toBe('opus');
  });

  it('labels mode, thinking, model, and git status', () => {
    expect(modeLabel('plan')).toBe('Plan');
    expect(thinkingLabel('extra-high')).toBe('Extra high');
    expect(modelLabel('opus', fallbackCaps('claude').models)).toBe('Opus');
    expect(workingTreeSubtitle({
      cwd: '/tmp/p',
      branch: 'main',
      ahead: 2,
      behind: 0,
      changed: 3,
      files: ['a'],
    })).toBe('main · ahead 2 · 3 changed');
  });

  it('clamps saved prefs to the active agent catalog', () => {
    const next = applyComposerPrefs(fallbackCaps('opencode'), {
      mode: 'ask',
      thinking: 'extra-high',
      model: 'missing',
    });
    expect(next.mode).toBe('agent');
    expect(next.thinking).toBe('medium');
    expect(next.model).toBe('opencode/deepseek-v4-flash-free');
  });
});
