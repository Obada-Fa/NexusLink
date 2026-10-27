import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createSign } from 'node:crypto';

export type PushProvider = 'fcm' | 'ntfy' | 'webhook';

export interface PushTokenRecord {
  token: string;
  provider: PushProvider;
  endpoint?: string;
  name?: string;
  createdAt: number;
  lastSeenAt: number;
}

interface FirebaseServiceAccount {
  project_id: string;
  private_key: string;
  client_email: string;
}

let activeSessionsCheck: (() => boolean) | null = null;
let cachedGoogleToken: { token: string; expiresAt: number } | null = null;

function getStorePath(): string {
  const dir = process.env.NEXUSLINK_DATA_DIR || join(homedir(), '.cache', 'nexuslink');
  if (!existsSync(dir)) {
    try {
      mkdirSync(dir, { recursive: true });
    } catch (_) {}
  }
  return join(dir, 'push_tokens.json');
}

export function loadPushTokens(): Map<string, PushTokenRecord> {
  const map = new Map<string, PushTokenRecord>();
  try {
    const file = getStorePath();
    if (existsSync(file)) {
      const raw = readFileSync(file, 'utf-8');
      const list = JSON.parse(raw);
      if (Array.isArray(list)) {
        for (const item of list) {
          if (item && typeof item.token === 'string') {
            map.set(item.token, {
              token: item.token,
              provider: item.provider ?? (item.endpoint?.includes('ntfy') ? 'ntfy' : 'fcm'),
              endpoint: item.endpoint,
              name: item.name,
              createdAt: item.createdAt ?? Date.now(),
              lastSeenAt: item.lastSeenAt ?? Date.now(),
            });
          }
        }
      }
    }
  } catch (err) {
    console.error('[push] error loading push tokens:', err);
  }
  return map;
}

export function savePushTokens(tokens: Map<string, PushTokenRecord>): void {
  try {
    const list = Array.from(tokens.values());
    writeFileSync(getStorePath(), JSON.stringify(list, null, 2), 'utf-8');
  } catch (err) {
    console.error('[push] error saving push tokens:', err);
  }
}

const memoryTokens = loadPushTokens();

export function setPushActiveSessionsCheck(fn: () => boolean): void {
  activeSessionsCheck = fn;
}

export function hasActivePushSessions(): boolean {
  if (!activeSessionsCheck) return false;
  try {
    return activeSessionsCheck();
  } catch {
    return false;
  }
}

export function registerPushToken(opts: {
  token: string;
  provider?: PushProvider;
  endpoint?: string;
  name?: string;
}): { ok: boolean; count: number } {
  const token = (opts.token ?? '').trim();
  if (!token) return { ok: false, count: memoryTokens.size };

  const provider: PushProvider =
    opts.provider ??
    (opts.endpoint?.includes('ntfy') || token.startsWith('https://ntfy.sh/') ? 'ntfy' : 'fcm');

  const now = Date.now();
  const existing = memoryTokens.get(token);
  memoryTokens.set(token, {
    token,
    provider,
    endpoint: opts.endpoint ?? (provider === 'ntfy' && token.startsWith('http') ? token : undefined),
    name: opts.name ?? existing?.name,
    createdAt: existing?.createdAt ?? now,
    lastSeenAt: now,
  });

  savePushTokens(memoryTokens);
  console.log(`[push] registered push token (${provider}) for device ${opts.name ?? 'unknown'}`);
  return { ok: true, count: memoryTokens.size };
}

export function listPushTokens(): PushTokenRecord[] {
  return Array.from(memoryTokens.values());
}

export function removePushToken(token: string): { ok: boolean } {
  const deleted = memoryTokens.delete(token.trim());
  if (deleted) savePushTokens(memoryTokens);
  return { ok: deleted };
}

function resolveServiceAccount(): FirebaseServiceAccount | null {
  const envPath = process.env.FIREBASE_SERVICE_ACCOUNT_PATH;
  const envJson = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  const configPath = join(homedir(), '.config', 'nexuslink', 'firebase-service-account.json');

  if (envJson) {
    try {
      return JSON.parse(envJson) as FirebaseServiceAccount;
    } catch (_) {}
  }
  const fileToRead = envPath && existsSync(envPath) ? envPath : existsSync(configPath) ? configPath : null;
  if (fileToRead) {
    try {
      const raw = readFileSync(fileToRead, 'utf-8');
      return JSON.parse(raw) as FirebaseServiceAccount;
    } catch (_) {}
  }
  return null;
}

async function getGoogleAccessToken(sa: FirebaseServiceAccount): Promise<string | null> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedGoogleToken && cachedGoogleToken.expiresAt > now + 60) {
    return cachedGoogleToken.token;
  }

  try {
    const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
    const claim = Buffer.from(
      JSON.stringify({
        iss: sa.client_email,
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
        aud: 'https://oauth2.googleapis.com/token',
        exp: now + 3600,
        iat: now,
      }),
    ).toString('base64url');

    const signer = createSign('RSA-SHA256');
    signer.update(`${header}.${claim}`);
    const signature = signer.sign(sa.private_key, 'base64url');
    const assertion = `${header}.${claim}.${signature}`;

    const res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
    });

    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      console.warn(`[push] OAuth2 token exchange failed: ${res.status} ${txt}`);
      return null;
    }

    const data = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!data.access_token) return null;

    cachedGoogleToken = {
      token: data.access_token,
      expiresAt: now + (data.expires_in ?? 3600),
    };
    return cachedGoogleToken.token;
  } catch (err) {
    console.error('[push] failed to generate Google access token:', err);
    return null;
  }
}

async function sendFcmPush(
  tokenRecord: PushTokenRecord,
  payload: { title: string; body: string; data?: Record<string, string> },
): Promise<boolean> {
  const sa = resolveServiceAccount();
  if (sa) {
    const accessToken = await getGoogleAccessToken(sa);
    if (accessToken) {
      try {
        const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
        const res = await fetch(url, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            message: {
              token: tokenRecord.token,
              notification: {
                title: payload.title,
                body: payload.body,
              },
              data: payload.data ?? {},
              android: {
                priority: 'high',
                notification: {
                  channel_id: 'agent_notifications',
                  sound: 'default',
                  priority: 'high',
                },
              },
              apns: {
                payload: {
                  aps: {
                    alert: {
                      title: payload.title,
                      body: payload.body,
                    },
                    sound: 'default',
                    badge: 1,
                  },
                },
              },
            },
          }),
        });

        if (res.ok) return true;
        const errText = await res.text().catch(() => '');
        if (res.status === 404 || errText.includes('UNREGISTERED') || errText.includes('NOT_FOUND')) {
          console.warn(`[push] token expired/unregistered; removing ${tokenRecord.token}`);
          removePushToken(tokenRecord.token);
        } else {
          console.warn(`[push] FCM send failed: ${res.status} ${errText}`);
        }
        return false;
      } catch (err) {
        console.error('[push] FCM HTTP request error:', err);
        return false;
      }
    }
  }

  // Fallback: Legacy FCM server key if configured
  const serverKey = process.env.FCM_SERVER_KEY;
  if (serverKey) {
    try {
      const res = await fetch('https://fcm.googleapis.com/fcm/send', {
        method: 'POST',
        headers: {
          Authorization: `key=${serverKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          to: tokenRecord.token,
          priority: 'high',
          notification: {
            title: payload.title,
            body: payload.body,
            sound: 'default',
          },
          data: payload.data ?? {},
        }),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  return false;
}

type PushPayload = { title: string; body: string; data?: Record<string, string> };

/** The topic URL a record publishes to (endpoint, URL token, or ntfy.sh/<token>). */
export function ntfyTopicUrl(tokenRecord: Pick<PushTokenRecord, 'token' | 'endpoint'>): string {
  return (
    tokenRecord.endpoint ??
    (tokenRecord.token.startsWith('http')
      ? tokenRecord.token
      : `https://ntfy.sh/${encodeURIComponent(tokenRecord.token)}`)
  );
}

/**
 * RFC 2047 encoded-word for HTTP header values. fetch() rejects non-Latin-1
 * header values outright (TypeError), which silently dropped every push whose
 * title contained "…" or an emoji. ntfy decodes =?UTF-8?B?...?= headers.
 */
export function rfc2047(value: string): string {
  if (/^[\x20-\x7e]*$/.test(value)) return value;
  return `=?UTF-8?B?${Buffer.from(value, 'utf8').toString('base64')}?=`;
}

/**
 * ntfy JSON publishing: POST {topic,title,message,...} to the server root.
 * The body is UTF-8 JSON, so titles need no header encoding at all.
 * Returns null when the URL has no topic segment to publish to.
 */
export function ntfyJsonRequest(topicUrl: string, payload: PushPayload): { url: string; init: RequestInit } | null {
  let parsed: URL;
  try { parsed = new URL(topicUrl); } catch { return null; }
  const segments = parsed.pathname.split('/');
  while (segments.length && !segments[segments.length - 1]) segments.pop();
  const topic = decodeURIComponent(segments.pop() ?? '');
  if (!topic) return null;
  parsed.pathname = `${segments.join('/')}/`;
  return {
    url: parsed.toString(),
    init: {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ topic, title: payload.title, message: payload.body, priority: 4, tags: ['robot', 'nexuslink'] }),
    },
  };
}

/** Classic header publishing (fallback for servers/URLs that reject JSON publishing). */
export function ntfyHeaderRequest(topicUrl: string, payload: PushPayload): { url: string; init: RequestInit } {
  return {
    url: topicUrl,
    init: {
      method: 'POST',
      headers: { Title: rfc2047(payload.title), Priority: 'high', Tags: 'robot,nexuslink' },
      body: payload.body,
    },
  };
}

async function sendNtfyPush(tokenRecord: PushTokenRecord, payload: PushPayload, fetcher: typeof fetch = fetch): Promise<boolean> {
  const url = ntfyTopicUrl(tokenRecord);
  try {
    const json = ntfyJsonRequest(url, payload);
    if (json) {
      const res = await fetcher(json.url, json.init);
      if (res.ok) return true;
      // Auth/rate-limit failures won't improve with the other format.
      if (![400, 404, 405, 415].includes(res.status)) return false;
    }
    const plain = ntfyHeaderRequest(url, payload);
    const res = await fetcher(plain.url, plain.init);
    return res.ok;
  } catch (err) {
    console.error(`[push] ntfy push error for ${url}:`, err instanceof Error ? err.message : err);
    return false;
  }
}

/** Test seam: publish one ntfy push through an injected fetch. */
export function sendNtfyPushForTests(tokenRecord: PushTokenRecord, payload: PushPayload, fetcher: typeof fetch): Promise<boolean> {
  return sendNtfyPush(tokenRecord, payload, fetcher);
}

async function sendWebhookPush(
  tokenRecord: PushTokenRecord,
  payload: { title: string; body: string; data?: Record<string, string> },
): Promise<boolean> {
  const url = tokenRecord.endpoint ?? tokenRecord.token;
  if (!url.startsWith('http')) return false;

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: payload.title,
        body: payload.body,
        data: payload.data,
        timestamp: Date.now(),
      }),
    });
    return res.ok;
  } catch (err) {
    console.error(`[push] webhook push error for ${url}:`, err);
    return false;
  }
}

export async function sendAgentPushNotification(opts: {
  title: string;
  body: string;
  agentSessionId?: string;
  sessionTitle?: string;
  kind?: string;
}): Promise<{ sent: number; failed: number }> {
  if (process.env.NEXUSLINK_DISABLE_PUSH === '1') return {sent:0,failed:0};
  const tokens = listPushTokens();
  if (tokens.length === 0) return { sent: 0, failed: 0 };

  const payload = {
    title: opts.title,
    body: opts.body,
    data: {
      agentSessionId: opts.agentSessionId ?? '',
      sessionTitle: opts.sessionTitle ?? '',
      kind: opts.kind ?? '',
      timestamp: String(Date.now()),
    },
  };

  let sent = 0;
  let failed = 0;

  const promises = tokens.map(async (rec) => {
    let success = false;
    if (rec.provider === 'fcm') {
      success = await sendFcmPush(rec, payload);
    } else if (rec.provider === 'ntfy') {
      success = await sendNtfyPush(rec, payload);
    } else if (rec.provider === 'webhook') {
      success = await sendWebhookPush(rec, payload);
    }
    if (success) sent++;
    else failed++;
  });

  await Promise.allSettled(promises);
  console.log(`[push] sent push notification "${opts.title}" -> ${sent} delivered, ${failed} failed`);
  return { sent, failed };
}

export async function sendTestPush(opts?: {
  title?: string;
  body?: string;
}): Promise<{ sent: number; failed: number }> {
  return sendAgentPushNotification({
    title: opts?.title ?? 'NexusLink Test Alert',
    body: opts?.body ?? 'This is a test background push notification from your PC.',
    kind: 'test',
  });
}
