import { describe, expect, test } from 'bun:test';
import { claudeModelLabel, listAgentModels, noteClaudeModel } from '../agents';

describe('Claude model labels', () => {
  test('turns full model ids into short versioned names', () => {
    expect(claudeModelLabel('claude-opus-5-5')).toBe('Opus 5.5');
    expect(claudeModelLabel('claude-haiku-4-5-20251001')).toBe('Haiku 4.5');
    expect(claudeModelLabel('claude-sonnet-5-5[1m]')).toBe('Sonnet 5.5 (1M)');
    expect(claudeModelLabel('something-odd-9')).toBe('Something 9');
  });

  test('shorthands show the model they last ran as and keep their ids', () => {
    noteClaudeModel('opus', 'claude-opus-5-5');
    noteClaudeModel(undefined, 'claude-opus-5-5');
    noteClaudeModel('haiku', 42);
    const models = listAgentModels('claude');
    const byId = Object.fromEntries(models.map((m) => [m.id, m.name]));
    expect(byId.opus).toBe('Opus 5.5');
    expect(byId.default).toBe('Default (Opus 5.5)');
    expect(byId.haiku).toBe('Haiku');
    expect(models.map((m) => m.id)).toContain('sonnet');
  });
});
