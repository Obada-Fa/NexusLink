import { expect, test } from 'bun:test';
import { validateRequest } from './protocol';

test('webrtc.signal accepts its object payload', () => {
  expect(() => validateRequest('webrtc.signal', { webrtcId: 'a', data: { kind: 'answer', sdp: 'v=0' } })).not.toThrow();
  expect(() => validateRequest('webrtc.signal', { webrtcId: 'a', data: { kind: 'ice', candidate: 'candidate:1', sdpMLineIndex: 0 } })).not.toThrow();
});

test('data must still be a string for every other method', () => {
  expect(() => validateRequest('terminal.input', { terminalId: 't', data: { kind: 'answer' } })).toThrow('Invalid data.');
  expect(() => validateRequest('terminal.input', { terminalId: 't', data: 'ls\n' })).not.toThrow();
});
