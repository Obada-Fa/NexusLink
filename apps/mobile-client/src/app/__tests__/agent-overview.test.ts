import { expect, it } from 'bun:test';
import { conversationState, groupConversations, matchesConversation } from '@/lib/agent-overview';

it('gives waiting approvals priority over working and completed states', () => {
  const chat = { agent: 'claude', title: 'Fix login', cwd: '/work/app', busy: true, taskState: 'running' };
  expect(conversationState(chat, true)).toBe('Needs you');
  expect(conversationState(chat)).toBe('Working');
  expect(conversationState({ ...chat, busy: false, taskState: 'failed' })).toBe('Failed');
  expect(conversationState({ ...chat, busy: false, taskState: 'completed' })).toBe('Completed');
});

it('searches by conversation, project, agent and preview without case sensitivity', () => {
  const chat = { agent: 'claude', title: 'Fix login', cwd: '/work/Nexus', preview: 'Review authentication' };
  for (const query of [' LOGIN ', 'nexus', 'Claude', 'authentication']) expect(matchesConversation(chat, query)).toBe(true);
  expect(matchesConversation(chat, 'missing')).toBe(false);
});

it('keeps same-named projects in different folders separate and shows latest chats first', () => {
  const chats = [
    { agent: 'claude', title: 'Old', cwd: '/work/app', updatedAt: 1 },
    { agent: 'codex', title: 'Other', cwd: '/personal/app', updatedAt: 2 },
    { agent: 'claude', title: 'Latest', cwd: '/work/app', updatedAt: 3 },
  ];
  const groups = groupConversations(chats);
  expect(groups.map(group => group.path)).toEqual(['/work/app', '/personal/app']);
  expect(groups[0]?.chats.map(chat => chat.title)).toEqual(['Latest', 'Old']);
  expect(chats[0]?.title).toBe('Old');
});
