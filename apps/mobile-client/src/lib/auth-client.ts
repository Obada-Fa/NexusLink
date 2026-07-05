const TOKEN_STORAGE_KEY = 'nexuslink-session-token';
const AUTH_STORAGE_KEY = 'nexuslink-auth-keypair';

let cachedKeyPair: CryptoKeyPair | null = null;
let cachedSecretKey: CryptoKey | null = null;

export async function generateKeyPair(): Promise<CryptoKeyPair> {
  const kp = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits'],
  );
  cachedKeyPair = kp;
  return kp;
}

export async function exportPublicKeyJwk(publicKey: CryptoKey): Promise<JsonWebKey> {
  return crypto.subtle.exportKey('jwk', publicKey);
}

export async function importPeerPublicKey(jwk: JsonWebKey): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );
}

export async function deriveSharedSecret(
  privateKey: CryptoKey,
  peerPublicKey: CryptoKey,
): Promise<CryptoKey> {
  const key = await crypto.subtle.deriveKey(
    { name: 'ECDH', public: peerPublicKey },
    privateKey,
    { name: 'HMAC', hash: 'SHA-1', length: 160 },
    false,
    ['sign'],
  );
  cachedSecretKey = key;
  return key;
}

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

export async function generateTOTP(
  secret: CryptoKey,
  stepMs = 30000,
  digits = 6,
): Promise<string> {
  const counter = Math.floor(Date.now() / stepMs);
  const counterBuf = counterToBuffer(counter);
  const hmac = await crypto.subtle.sign({ name: 'HMAC' }, secret, counterBuf);
  return hotpTruncate(hmac, digits);
}

export async function validateTOTP(
  code: string,
  secret: CryptoKey,
  stepMs = 30000,
  tolerance = 1,
): Promise<boolean> {
  const currentStep = Math.floor(Date.now() / stepMs);

  for (let offset = -tolerance; offset <= tolerance; offset++) {
    const counter = currentStep + offset;
    const counterBuf = counterToBuffer(counter);
    const hmac = await crypto.subtle.sign({ name: 'HMAC' }, secret, counterBuf);
    const expected = hotpTruncate(hmac, 6);
    if (expected === code) {
      return true;
    }
  }

  return false;
}

export function storeToken(token: string): void {
  try {
    localStorage.setItem(TOKEN_STORAGE_KEY, token);
  } catch {
    // storage unavailable
  }
}

export function getToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_STORAGE_KEY);
  } catch {
    return null;
  }
}

export function clearToken(): void {
  try {
    localStorage.removeItem(TOKEN_STORAGE_KEY);
  } catch {
    // storage unavailable
  }
}

export function attachToken(
  message: Record<string, unknown>,
  token?: string,
): Record<string, unknown> {
  const t = token ?? getToken();
  if (!t) return message;
  return { ...message, auth_token: t };
}

export async function saveKeyPair(kp: CryptoKeyPair): Promise<void> {
  const jwk = await crypto.subtle.exportKey('jwk', kp.privateKey);
  try {
    localStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify(jwk));
  } catch {
    // storage unavailable
  }
}

export async function loadKeyPair(): Promise<CryptoKeyPair | null> {
  try {
    const raw = localStorage.getItem(AUTH_STORAGE_KEY);
    if (!raw) return null;

    const jwk = JSON.parse(raw) as JsonWebKey;
    const privateKey = await crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'ECDH', namedCurve: 'P-256' },
      true,
      ['deriveBits'],
    );

    // Reconstruct public key from private
    const rawPriv = await crypto.subtle.exportKey('jwk', privateKey);
    const pubJwk: JsonWebKey = {
      kty: rawPriv.kty,
      crv: rawPriv.crv,
      x: rawPriv.x,
      y: rawPriv.y,
    };

    const publicKey = await crypto.subtle.importKey(
      'jwk',
      pubJwk,
      { name: 'ECDH', namedCurve: 'P-256' },
      true,
      [],
    );

    cachedKeyPair = { privateKey, publicKey };
    return cachedKeyPair;
  } catch {
    return null;
  }
}

export function clearKeyPair(): void {
  cachedKeyPair = null;
  cachedSecretKey = null;
  try {
    localStorage.removeItem(AUTH_STORAGE_KEY);
  } catch {
    // storage unavailable
  }
}

export function getCachedSecret(): CryptoKey | null {
  return cachedSecretKey;
}

export async function performPairingHandshake(
  hostUrl: string,
  sendPairRequest: (params: { publicKey: string }) => Promise<{ publicKey: string; totpIssuerUri: string }>,
  sendAuthRequest: (params: { code: string }) => Promise<{ token: string }>,
): Promise<string> {
  let kp = cachedKeyPair ?? (await loadKeyPair());
  if (!kp) {
    kp = await generateKeyPair();
    await saveKeyPair(kp);
  }

  const myPubJwk = await exportPublicKeyJwk(kp.publicKey);
  const myPubStr = JSON.stringify(myPubJwk);

  const pairResp = await sendPairRequest({ publicKey: myPubStr });
  const peerPubJwk = JSON.parse(pairResp.publicKey) as JsonWebKey;
  const peerPublicKey = await importPeerPublicKey(peerPubJwk);
  const secret = await deriveSharedSecret(kp.privateKey, peerPublicKey);

  const totpCode = await generateTOTP(secret);
  const authResp = await sendAuthRequest({ code: totpCode });

  storeToken(authResp.token);

  // Verify server can also validate our TOTP
  const verified = await validateTOTP(authResp.token, secret);
  if (!verified) {
    clearToken();
    throw new Error('TOTP validation failed during pairing');
  }

  return authResp.token;
}
