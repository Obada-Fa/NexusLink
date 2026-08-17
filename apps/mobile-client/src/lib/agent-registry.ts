import type { AgentId } from '@nexuslink/rpc-types';

export interface AgentUiConfig {
  id: AgentId;
  label: string;
  shortLabel: string;
  icon: string;
  accent: string;
  description: string;
  chatHint: string;
  terminalHint: string;
  quickActions?: Array<{ id: string; label: string; prompt?: string; terminalCommand?: string; externalUrl?: string }>;
}

export const AGENT_UI: AgentUiConfig[] = [
  {
    id: 'cursor',
    label: 'Cursor Agent',
    shortLabel: 'Cursor',
    icon: '⌁',
    accent: '#2a6aff',
    description: 'Cursor CLI on your desktop — chat from your phone or open the full terminal UI.',
    chatHint: 'Runs `agent -p` on your PC. Great for quick fixes and questions.',
    terminalHint: 'Full interactive Cursor CLI (Shift+Tab, /commands, Ctrl+D to exit).',
    quickActions: [
      { id: 'resume', label: 'Resume last chat', terminalCommand: 'agent resume\r' },
      { id: 'status', label: 'Auth status', terminalCommand: 'agent status\r' },
      { id: 'worker', label: 'Start worker', terminalCommand: 'agent worker start\r' },
      { id: 'web', label: 'cursor.com/agents', externalUrl: 'https://cursor.com/agents' },
    ],
  },
  {
    id: 'opencode',
    label: 'OpenCode',
    shortLabel: 'OpenCode',
    icon: '◈',
    accent: '#f97316',
    description: 'OpenCode TUI and headless runs on your desktop, controlled from your phone.',
    chatHint: 'Runs `opencode run` for one-shot tasks. Toggle “Continue session” to keep context.',
    terminalHint: 'Full OpenCode TUI with slash commands and !shell support.',
    quickActions: [
      { id: 'continue', label: 'Continue session', prompt: 'Continue the previous session.', terminalCommand: undefined },
      { id: 'list', label: 'List agents', terminalCommand: 'opencode agent list\r' },
    ],
  },
  {
    id: 'antigravity',
    label: 'Antigravity',
    shortLabel: 'Antigravity',
    icon: '⬡',
    accent: '#a855f7',
    description: 'Google Antigravity CLI (`agy`) — terminal-first agent on your desktop.',
    chatHint: 'Antigravity is TUI-only. Use Terminal mode for real work.',
    terminalHint: 'Interactive `agy` session. Use /config, /help, and Ctrl+K to approve tools.',
    quickActions: [
      { id: 'help', label: 'Open /help', terminalCommand: '/help\r' },
      { id: 'config', label: 'Open /config', terminalCommand: '/config\r' },
    ],
  },
];

export function agentUi(id: AgentId): AgentUiConfig {
  return AGENT_UI.find((a) => a.id === id) ?? AGENT_UI[0];
}

export const AGENT_TOOLBAR_KEYS = [
  { label: 'Tab', code: '\t' },
  { label: 'Esc', code: '\x1b' },
  { label: 'Ctrl', code: 'CTRL', modifier: true as const },
  { label: 'Shift', code: 'SHIFT', modifier: true as const },
  { label: '/', code: '/' },
  { label: 'Enter', code: '\r' },
  { label: 'Ctrl+D', code: 'CTRL_D' },
  { label: 'Shift+Tab', code: '\x1b[Z' },
  { label: '↑', code: '\x1b[A' },
  { label: '↓', code: '\x1b[B' },
];
