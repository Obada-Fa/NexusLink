import { describe, expect, test } from 'bun:test';
import {
  extractProtobufStrings,
  parseAgyStepStrings,
  parseCursorJsonl,
  parseCursorTranscriptLine,
  parseOpencodeExport,
} from '../host-chats';

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

  test('parses Cursor transcript jsonl including tool_use', () => {
    const jsonl = [
      JSON.stringify({
        role: 'user',
        message: { content: [{ type: 'text', text: 'fix the tests' }] },
      }),
      JSON.stringify({
        role: 'assistant',
        message: {
          content: [
            { type: 'tool_use', id: 'c1', name: 'Read', input: { path: 'a.ts' } },
            { type: 'text', text: 'Looking now.' },
          ],
        },
      }),
    ].join('\n');
    const events = parseCursorJsonl(jsonl);
    expect(events[0]).toMatchObject({ kind: 'user', text: 'fix the tests' });
    expect(events.some((e) => e.kind === 'tool-start' && e.toolName === 'Read')).toBe(true);
    expect(events.some((e) => e.kind === 'text' && e.text === 'Looking now.')).toBe(true);
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
