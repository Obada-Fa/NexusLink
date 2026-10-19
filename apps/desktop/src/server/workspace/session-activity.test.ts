import { expect, test } from 'bun:test';
import { sessionActivity } from './session-activity';
test('describes observed tool work without guessing percent or test results', () => {
  for(const toolName of ['Edit','Write','apply_patch','File changes','replace'])expect(sessionActivity({kind:'tool-start',toolName})).toBe('editing');
  for(const toolName of ['Read','Grep','web.search','read_file'])expect(sessionActivity({kind:'tool-start',toolName})).toBe('reading');
  for(const toolName of ['Shell','Bash','exec_command'])expect(sessionActivity({kind:'tool-start',toolName})).toBe('running-command');
  expect(sessionActivity({kind:'tool-start',toolName:'unknown-plugin'})).toBe('working');
  expect(sessionActivity({kind:'tool-end'})).toBe('working');
  expect(sessionActivity({kind:'thinking'})).toBe('thinking');
  expect(sessionActivity({kind:'text-delta'})).toBe('responding');
  expect(sessionActivity({kind:'result'})).toBeUndefined();
});
