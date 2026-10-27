import { expect, test } from 'bun:test';
import { matchAgentApp } from '../agent-apps';

// Command lines as they appear in /proc on the owner's PC.
test('desktop agent apps are recognised by their main executable', () => {
  expect(matchAgentApp(['/home/obada/Applications/Antigravity/antigravity'], 'antigravity')?.appId).toBe('antigravity');
  expect(matchAgentApp(['/usr/lib/chatgpt/ChatGPT', '--type=renderer'], 'ChatGPT')?.appId).toBe('codex-desktop');
  expect(matchAgentApp(['/usr/lib/claude-desktop/claude-desktop', '--password-store=basic'], 'claude-desktop')).toEqual({ appId: 'claude-desktop', kind: 'desktop' });
  expect(matchAgentApp(['/tmp/.mount_CursorXyz/cursor'], 'cursor')?.appId).toBe('cursor');
});

test('agent CLIs are recognised without being confused with their desktop apps', () => {
  expect(matchAgentApp(['claude', '--resume=abc'], 'claude')).toEqual({ appId: 'claude-code', kind: 'cli' });
  expect(matchAgentApp(['node', '/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js'], 'node')?.appId).toBe('claude-code');
  expect(matchAgentApp(['/usr/local/bin/codex', 'exec', 'fix it'], 'codex')?.appId).toBe('codex-cli');
  // The Codex desktop app bundles its own codex binary: it belongs to the desktop app.
  expect(matchAgentApp(['/usr/lib/chatgpt/resources/codex', 'app-server', '--listen', 'stdio://'], 'codex')).toBeNull();
  expect(matchAgentApp(['cursor-agent', '--print'], 'cursor-agent')?.appId).toBe('cursor-agent');
  expect(matchAgentApp(['node', '/home/u/.npm/_npx/x/node_modules/@google/gemini-cli/dist/index.js'], 'node')?.appId).toBe('gemini-cli');
  expect(matchAgentApp(['opencode'], 'opencode')?.appId).toBe('opencode');
});

test('ordinary processes are not agents', () => {
  expect(matchAgentApp(['/usr/bin/gnome-shell'], 'gnome-shell')).toBeNull();
  expect(matchAgentApp(['bash'], 'bash')).toBeNull();
  expect(matchAgentApp(['/usr/share/code/code', '--type=zygote'], 'code')?.appId).toBe('vscode');
  expect(matchAgentApp([], 'kworker/0:1')).toBeNull();
});
