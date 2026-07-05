interface TokenEntry {
  token: string;
  expires: number;
}

const tokens = new Map<string, TokenEntry>();

export function generateToken(): { token: string; expires: number } {
  const token = crypto.randomUUID();
  const expires = Date.now() + 24 * 60 * 60 * 1000; // 24h
  tokens.set(token, { token, expires });
  return { token, expires };
}

export function validateToken(token: string): boolean {
  const entry = tokens.get(token);
  if (!entry) return false;
  if (Date.now() > entry.expires) {
    tokens.delete(token);
    return false;
  }
  return true;
}

export function revokeToken(token: string): void {
  tokens.delete(token);
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

function counterToBuffer(counter: number): ArrayBuffer {
  const buf = new ArrayBuffer(8);
  const view = new DataView(buf);
  view.setBigUint64(0, BigInt(counter));
  return buf;
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
    ['deriveBits'],
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
  tolerance = 1,
): Promise<boolean> {
  const session = pairings.get(pairingReference);
  if (!session || !session.secret) return false;

  const currentStep = Math.floor(Date.now() / stepMs);

  for (let offset = -tolerance; offset <= tolerance; offset++) {
    const counter = currentStep + offset;
    const counterBuf = counterToBuffer(counter);
    const hmac = await crypto.subtle.sign({ name: 'HMAC' }, session.secret, counterBuf);
    const expected = hotpTruncate(hmac, 6);
    if (expected === code) return true;
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
