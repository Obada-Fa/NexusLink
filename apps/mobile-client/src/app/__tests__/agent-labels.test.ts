import { describe, expect, it } from 'bun:test';
import { agentSourceLabel, chatListSubtitle } from '@/lib/agent-labels';

describe('agent chat list labels', () => {
  it('uses known names and title-cases unknown agents', () => {
    expect(agentSourceLabel('opencode')).toBe('OpenCode');
    expect(agentSourceLabel('claude')).toBe('Claude Code');
    expect(agentSourceLabel('future-bot')).toBe('Future Bot');
    expect(agentSourceLabel('cursor', 'Cursor CLI')).toBe('Cursor CLI');
  });

  it('formats source · folder like Cursor rows', () => {
    expect(chatListSubtitle({
      agent: 'opencode',
      cwd: '/tmp/proj',
    })).toBe('OpenCode · /tmp/proj');
    expect(chatListSubtitle({
      agent: 'claude',
      cwd: '/home/me',
      resumable: false,
    })).toBe('Claude Code · /home/me · view only');
  });
});
