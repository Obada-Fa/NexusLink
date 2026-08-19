import { persistToken, persistedTokenValid, forgetToken, hydratePersistedTokens } from '../persist';

interface TokenEntry {
  token: string;
  expires: number;
}

const tokens = new Map<string, TokenEntry>();
hydratePersistedTokens();

export function generateToken(): { token: string; expires: number } {
  const token = crypto.randomUUID();
  const expires = Date.now() + 24 * 60 * 60 * 1000; // 24h
  tokens.set(token, { token, expires });
  persistToken(token, expires);
  return { token, expires };
}

export function validateToken(token: string): boolean {
  const entry = tokens.get(token);
  if (entry) {
    if (Date.now() > entry.expires) {
      tokens.delete(token);
      forgetToken(token);
      return false;
    }
    return true;
  }
  return persistedTokenValid(token);
}

export function revokeToken(token: string): void {
  tokens.delete(token);
  forgetToken(token);
}

export function cleanupExpired(): void {
  const now = Date.now();
  tokens.forEach((entry, token) => {
    if (now > entry.expires) tokens.delete(token);
  });
}

// ---- ECDH pairing ----

interface PairingSession {
  serverKeyPair: CryptoKeyPair;
  secret: CryptoKey | null;
  createdAt: number;
}

const pairings = new Map<string, PairingSession>();

function counterToBuffer(counter: number, littleEndian = false): ArrayBuffer {
  const buf = new ArrayBuffer(8);
  const view = new DataView(buf);
  view.setBigUint64(0, BigInt(counter), littleEndian);
  return buf;
}

/** RFC1918 / Tailscale / loopback — the phone on the same LAN as this host. */
export function isTrustedLan(address?: string): boolean {
  if (!address) return false;
  const ip = address.replace(/^::ffff:/i, '');
  if (ip === '127.0.0.1' || ip === '::1' || ip === 'localhost') return true;
  const m = ip.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const a = Number(m[1]);
  const b = Number(m[2]);
  if (a === 10) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 100 && b >= 64 && b <= 127) return true; // Tailscale CGNAT
  return false;
}

function hotpTruncate(hmacResult: ArrayBuffer, digits: number): string {
  const bytes = new Uint8Array(hmacResult);
  const offset = bytes[bytes.length - 1]! & 0x0f;
  const binary =
    ((bytes[offset]! & 0x7f) << 24) |
    ((bytes[offset + 1]! & 0xff) << 16) |
    ((bytes[offset + 2]! & 0xff) << 8) |
    (bytes[offset + 3]! & 0xff);
  const mod = Math.pow(10, digits);
  return (binary % mod).toString().padStart(digits, '0');
}

export async function handleSessionPair(publicKey: string): Promise<{ publicKey: string; totpIssuerUri: string }> {
  const serverKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveKey'],
  );

  const peerPubJwk = JSON.parse(publicKey) as JsonWebKey;
  const peerPublicKey = await crypto.subtle.importKey(
    'jwk',
    peerPubJwk,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );

  const secret = await crypto.subtle.deriveKey(
    { name: 'ECDH', public: peerPublicKey },
    serverKeyPair.privateKey,
    { name: 'HMAC', hash: 'SHA-1', length: 160 },
    false,
    ['sign'],
  );

  const pairingId = crypto.randomUUID();
  pairings.set(pairingId, {
    serverKeyPair,
    secret,
    createdAt: Date.now(),
  });

  const serverPubJwk = await crypto.subtle.exportKey('jwk', serverKeyPair.publicKey);

  return {
    publicKey: JSON.stringify(serverPubJwk),
    totpIssuerUri: `otpauth://totp/NexusLink?secret=${pairingId}&issuer=NexusLink`,
  };
}

export async function validateSessionTOTP(
  pairingReference: string,
  code: string,
  stepMs = 30000,
  // ±10 steps = ±5min: phone clocks are often still skewed after a manual
  // timezone fix, and the pairing secret is ephemeral.
  tolerance = 10,
): Promise<boolean> {
  const session = pairings.get(pairingReference);
  if (!session || !session.secret) return false;

  const currentStep = Math.floor(Date.now() / stepMs);
  const received = String(code ?? '').trim();

  // Big-endian is RFC 4226; also try little-endian — Dart ByteData on some
  // devices uses host endian for setUint64, which is LE on Android.
  for (const littleEndian of [false, true]) {
    for (let offset = -tolerance; offset <= tolerance; offset++) {
      const counterBuf = counterToBuffer(currentStep + offset, littleEndian);
      const hmac = await crypto.subtle.sign({ name: 'HMAC' }, session.secret, counterBuf);
      if (hotpTruncate(hmac, 6) === received) return true;
    }
  }

  return false;
}

export function isLocalDev(url: string): boolean {
  try {
    const host = new URL(url).hostname;
    return host === 'localhost' || host === '127.0.0.1' || host === '::1';
  } catch {
    return false;
  }
}

export function generateDevToken(): { token: string; expires: number } {
  const devToken = `dev-${crypto.randomUUID()}`;
  const expires = Date.now() + 24 * 60 * 60 * 1000;
  tokens.set(devToken, { token: devToken, expires });
  persistToken(devToken, expires);
  return { token: devToken, expires };
}

export function cleanupPairings(): void {
  const now = Date.now();
  const expiry = 5 * 60 * 1000; // 5min pairing window
  pairings.forEach((session, id) => {
    if (now - session.createdAt > expiry) pairings.delete(id);
  });
}

setInterval(cleanupPairings, 60_000);
