import { describe, expect, test, beforeEach } from 'bun:test';
import {
  registerPushToken,
  listPushTokens,
  removePushToken,
  sendAgentPushNotification,
  setPushActiveSessionsCheck,
  hasActivePushSessions,
} from '../push';

describe('push notifications handler', () => {
  beforeEach(() => {
    // Clear tokens for tests
    const list = listPushTokens();
    for (const t of list) {
      removePushToken(t.token);
    }
  });

  test('registerPushToken registers and lists tokens', () => {
    const res = registerPushToken({
      token: 'test-fcm-token-123',
      provider: 'fcm',
      name: 'Pixel 9',
    });
    expect(res.ok).toBe(true);

    const tokens = listPushTokens();
    expect(tokens.some((t) => t.token === 'test-fcm-token-123')).toBe(true);
    const item = tokens.find((t) => t.token === 'test-fcm-token-123')!;
    expect(item.name).toBe('Pixel 9');
    expect(item.provider).toBe('fcm');
  });

  test('removePushToken deletes token correctly', () => {
    registerPushToken({ token: 'test-token-to-delete', provider: 'ntfy' });
    expect(listPushTokens().some((t) => t.token === 'test-token-to-delete')).toBe(true);

    const del = removePushToken('test-token-to-delete');
    expect(del.ok).toBe(true);
    expect(listPushTokens().some((t) => t.token === 'test-token-to-delete')).toBe(false);
  });

  test('hasActivePushSessions correctly reflects active sessions check callback', () => {
    setPushActiveSessionsCheck(() => true);
    expect(hasActivePushSessions()).toBe(true);

    setPushActiveSessionsCheck(() => false);
    expect(hasActivePushSessions()).toBe(false);
  });

  test('sendAgentPushNotification with no tokens does not fail', async () => {
    const res = await sendAgentPushNotification({
      title: 'Agent Done',
      body: 'Task finished',
    });
    expect(res.sent).toBe(0);
    expect(res.failed).toBe(0);
  });
});
