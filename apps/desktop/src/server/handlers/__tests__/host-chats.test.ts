import { describe, expect, test } from 'bun:test';
import {
  cleanMessageText,
  agySourceLabel,
  agentSourceLabel,
  chatListSubtitle,
  cwdFromAgyCliHistory,
  cwdFromAgyProjectResources,
  cwdFromDashedSlug,
  extractProtobufStrings,
  parseAgyCliHistoryLine,
  normalizeHostChat,
  fileUriToPath,
  parseAgyJsonl,
  parseAgyStepStrings,
  parseAgyWorkspaceUris,
  parseClaudeJsonl,
  parseCursorJsonl,
  parseCursorTranscriptLine,
  parseOpencodeExport,
} from '../host-chats';
import { realpathSync } from 'node:fs';

describe('cleanMessageText', () => {
  test('strips timestamp and extracts inner user_query text', () => {
    const raw =
      '<timestamp>Tuesday, Aug 18, 2026, 1:01 AM (UTC+2)</timestamp>\n<user_query>\ni want to open this project in cursor give me the copiable path\n</user_query>';
    expect(cleanMessageText(raw)).toBe('i want to open this project in cursor give me the copiable path');
  });

  test('strips Antigravity USER_REQUEST and ADDITIONAL_METADATA blocks', () => {
    const raw =
      '<USER_REQUEST>\ncan you check why my ethernet connection is not working\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-08-04T22:13:02+02:00.\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection`\n</USER_SETTINGS_CHANGE>';
    expect(cleanMessageText(raw)).toBe('can you check why my ethernet connection is not working');
  });

  test('preserves normal plain text unchanged', () => {
    expect(cleanMessageText('Hello world! How are you?')).toBe('Hello world! How are you?');
  });
});

describe('host chat parsers', () => {
  test('turns an OpenCode export into user/text/tool events', () => {
    const events = parseOpencodeExport({
      info: { id: 'ses_1', title: 'Demo' },
      messages: [
        {
          info: { role: 'user', time: { created: 100 } },
          parts: [{ type: 'text', text: 'hello there' }],
        },
        {
          info: { role: 'assistant', time: { created: 200 } },
          parts: [
            { type: 'thinking', text: 'hmm' },
            {
              type: 'tool',
              tool: 'bash',
              id: 't1',
              state: { input: { command: 'ls' }, output: 'a.txt' },
            },
            { type: 'text', text: 'done' },
          ],
        },
      ],
    });
    expect(events.map((e) => e.kind)).toEqual([
      'user', 'thinking', 'tool-start', 'tool-end', 'text',
    ]);
    expect(events[0]!.text).toBe('hello there');
    expect(events[2]!.toolName).toBe('bash');
    expect(events[3]!.toolOutput).toBe('a.txt');
    expect(events[4]!.text).toBe('done');
  });

  test('parses Cursor transcript jsonl and strips timestamp wrappers', () => {
    const jsonl = [
      JSON.stringify({
        role: 'user',
        message: {
          content: [
            {
              type: 'text',
              text: '<timestamp>Monday, Aug 17, 2026, 11:24 PM (UTC+2)</timestamp>\n<user_query>\nfix the tests\n</user_query>',
            },
          ],
        },
      }),
      JSON.stringify({
        role: 'assistant',
        message: {
          content: [
            { type: 'tool_use', id: 'c1', name: 'Read', input: { path: 'a.ts' } },
            { type: 'text', text: 'Looking now.\n[REDACTED]' },
          ],
        },
      }),
    ].join('\n');
    const events = parseCursorJsonl(jsonl);
    expect(events[0]).toMatchObject({ kind: 'user', text: 'fix the tests' });
    expect(events.some((e) => e.kind === 'tool-start' && e.toolName === 'Read')).toBe(true);
    expect(events.some((e) => e.kind === 'text' && e.text === 'Looking now.')).toBe(true);
  });

  test('parses Antigravity transcript jsonl', () => {
    const jsonl = [
      JSON.stringify({
        type: 'USER_INPUT',
        created_at: '2026-08-04T20:13:02Z',
        content: '<USER_REQUEST>\ncheck ethernet\n</USER_REQUEST>\n<ADDITIONAL_METADATA>...</ADDITIONAL_METADATA>',
      }),
      JSON.stringify({
        type: 'PLANNER_RESPONSE',
        created_at: '2026-08-04T20:13:03Z',
        content: 'Checking now.',
        tool_calls: [{ name: 'run_command', args: { CommandLine: 'ip a' } }],
      }),
    ].join('\n');
    const events = parseAgyJsonl(jsonl);
    expect(events[0]).toMatchObject({ kind: 'user', text: 'check ethernet' });
    expect(events[1]).toMatchObject({ kind: 'text', text: 'Checking now.' });
    expect(events[2]).toMatchObject({ kind: 'tool-start', toolName: 'run_command' });
  });

  test('parses Claude Code transcript jsonl', () => {
    const jsonl = [
      JSON.stringify({
        type: 'user',
        timestamp: '2026-07-22T17:17:35.775Z',
        message: {
          role: 'user',
          content: 'build a music share app',
        },
      }),
      JSON.stringify({
        type: 'assistant',
        timestamp: '2026-07-22T17:17:38.470Z',
        message: {
          role: 'assistant',
          content: [
            { type: 'thinking', thinking: 'Exploring structure' },
            { type: 'text', text: 'I will explore the codebase.' },
            { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'git status' } },
          ],
        },
      }),
      JSON.stringify({
        type: 'user',
        timestamp: '2026-07-22T17:17:39.000Z',
        message: {
          role: 'user',
          content: [
            { type: 'tool_result', tool_use_id: 't1', content: 'On branch main' },
          ],
        },
      }),
    ].join('\n');
    const events = parseClaudeJsonl(jsonl);
    expect(events.map((e) => e.kind)).toEqual([
      'user', 'thinking', 'text', 'tool-start', 'tool-end',
    ]);
    expect(events[0]!.text).toBe('build a music share app');
    expect(events[1]!.text).toBe('Exploring structure');
    expect(events[2]!.text).toBe('I will explore the codebase.');
    expect(events[3]!.toolName).toBe('Bash');
    expect(events[4]!.toolOutput).toBe('On branch main');
  });

  test('parseCursorTranscriptLine accepts a flat role/text blob', () => {
    expect(parseCursorTranscriptLine({ role: 'user', text: 'hi' })).toEqual([
      expect.objectContaining({ kind: 'user', text: 'hi' }),
    ]);
  });

  test('extracts UTF-8 strings from protobuf length-delimited fields', () => {
    const text = 'Continue the refactor';
    const payload = Buffer.concat([
      Buffer.from([0x0a, text.length]),
      Buffer.from(text),
    ]);
    expect(extractProtobufStrings(payload)).toEqual([text]);
    const events = parseAgyStepStrings(['abc', 'Please look at src/main.ts for the crash']);
    expect(events[0]!.kind).toBe('user');
    expect(events[0]!.text).toContain('src/main.ts');
  });
});

describe('Antigravity workspace paths', () => {
  test('parses file URIs and workspace_uris JSON', () => {
    expect(fileUriToPath('file:///home/user/Projects/mobile/opendesktop'))
      .toBe('/home/user/Projects/mobile/opendesktop');
    expect(fileUriToPath('file:///home/user/Programming/market%20place'))
      .toBe('/home/user/Programming/market place');
    expect(parseAgyWorkspaceUris('["file:///tmp"]')).toBe(realpathSync('/tmp'));
    expect(parseAgyWorkspaceUris('')).toBe('');
  });

  test('reads folderUri from Antigravity project JSON', () => {
    expect(cwdFromAgyProjectResources({
      id: 'abc',
      projectResources: {
        resources: [{ gitFolder: { folderUri: 'file:///tmp' } }],
      },
    })).toBe(realpathSync('/tmp'));
    expect(cwdFromAgyProjectResources({
      resources: [{ folderUri: 'file:///tmp' }],
    })).toBe(realpathSync('/tmp'));
    expect(cwdFromAgyProjectResources({ id: 'default-cli-project', projectResources: {} })).toBe('');
    expect(cwdFromAgyProjectResources({ name: '/tmp', projectResources: {} })).toBe(realpathSync('/tmp'));
  });
});

describe('Antigravity CLI history cwd', () => {
  test('labels CLI vs IDE sources', () => {
    expect(agySourceLabel('antigravity-cli')).toBe('Antigravity CLI');
    expect(agySourceLabel('antigravity')).toBe('Antigravity');
    expect(agySourceLabel('')).toBe('Antigravity');
  });

  test('parses history.jsonl workspace lines', () => {
    expect(parseAgyCliHistoryLine({
      display: 'uploadapk assets on github',
      workspace: '/tmp',
      conversationId: 'abc',
    })).toEqual({
      conversationId: 'abc',
      workspace: realpathSync('/tmp'),
      display: 'uploadapk assets on github',
    });
    expect(parseAgyCliHistoryLine({ display: 'no folder' })).toBeNull();
  });

  test('resolves cwd from conversation id then preview text', () => {
    const entries = [
      { conversationId: '', workspace: '/old', display: 'ignore me please now' },
      { conversationId: 'chat-1', workspace: '/from-id', display: 'uploadapk assets on github' },
      { conversationId: '', workspace: '/from-preview', display: 'Agent Menu Tabs Layout' },
    ];
    expect(cwdFromAgyCliHistory('chat-1', 'other preview text here', entries)).toBe('/from-id');
    expect(cwdFromAgyCliHistory('missing', 'Agent Menu Tabs Layout extra', entries)).toBe('/from-preview');
    expect(cwdFromAgyCliHistory('missing', 'hi', entries)).toBe('');
  });
});

describe('unified chat list metadata', () => {
  test('labels known agents and title-cases future ones', () => {
    expect(agentSourceLabel('opencode')).toBe('OpenCode');
    expect(agentSourceLabel('claude')).toBe('Claude Code');
    expect(agentSourceLabel('cool-agent')).toBe('Cool Agent');
    expect(agentSourceLabel('cursor', 'Cursor IDE')).toBe('Cursor IDE');
  });

  test('formats source · folder for every agent', () => {
    expect(chatListSubtitle({ agent: 'opencode', cwd: '/tmp/proj' }))
      .toBe('OpenCode · /tmp/proj');
    expect(chatListSubtitle({ agent: 'claude', cwd: '/tmp', resumable: false }))
      .toBe('Claude Code · /tmp · view only');
  });

  test('reconstructs cwd from dashed project slugs', () => {
    expect(cwdFromDashedSlug('tmp')).toBe(realpathSync('/tmp'));
    expect(cwdFromDashedSlug('-tmp')).toBe(realpathSync('/tmp'));
  });

  test('fills a missing source from the agent id', () => {
    expect(normalizeHostChat({
      agent: 'opencode',
      hostChatId: 's1',
      title: 'hi',
      cwd: '/tmp',
      updatedAt: 1,
      resumable: true,
      source: '',
    }).source).toBe('OpenCode');
  });
});
