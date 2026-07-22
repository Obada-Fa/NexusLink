// Pairing crypto for the PWA. Implemented with pure-JS primitives
// (@noble/curves, @noble/hashes) instead of WebCrypto because the PWA is served
// over plain HTTP on the LAN (http://<pc-ip>:45678), which is NOT a secure
// context — browsers hide `crypto.subtle` there, and the handshake must still
// work. `crypto.getRandomValues` (all noble needs) is available everywhere.
//
// Wire-compat with the host (apps/desktop/src/server/handlers/auth.ts), which
// uses WebCrypto ECDH P-256 + deriveKey({HMAC,SHA-1,length:160}): the HMAC key
// is the leftmost 160 bits (20 bytes) of the shared point's X coordinate.

import { p256 } from '@noble/curves/nist.js';
import { hmac } from '@noble/hashes/hmac.js';
import { sha1 } from '@noble/hashes/legacy.js';

const TOKEN_STORAGE_KEY = 'nexuslink-session-token';
const AUTH_STORAGE_KEY = 'nexuslink-auth-secretkey';

export interface PairingKeyPair {
  secretKey: Uint8Array;
  /** Uncompressed SEC1 point: 0x04 || X (32) || Y (32) */
  publicKey: Uint8Array;
}

let cachedKeyPair: PairingKeyPair | null = null;

// ---------------------------------------------------------------------------
// base64url helpers (JWK x/y are unpadded base64url)
// ---------------------------------------------------------------------------

function bytesToB64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

// ---------------------------------------------------------------------------
// Key management
// ---------------------------------------------------------------------------

export function generateKeyPair(): PairingKeyPair {
  const secretKey = p256.utils.randomSecretKey();
  const publicKey = p256.getPublicKey(secretKey, false);
  cachedKeyPair = { secretKey, publicKey };
  return cachedKeyPair;
}

/** JWK for our public key, as the host expects in `session.pair`. */
export function exportPublicKeyJwk(kp: PairingKeyPair): JsonWebKey {
  return {
    kty: 'EC',
    crv: 'P-256',
    x: bytesToB64url(kp.publicKey.slice(1, 33)),
    y: bytesToB64url(kp.publicKey.slice(33, 65)),
  };
}

/** Peer JWK -> uncompressed SEC1 point bytes. */
export function importPeerPublicKey(jwk: JsonWebKey): Uint8Array {
  if (!jwk.x || !jwk.y) throw new Error('peer JWK missing x/y');
  const x = b64urlToBytes(jwk.x);
  const y = b64urlToBytes(jwk.y);
  const point = new Uint8Array(65);
  point[0] = 0x04;
  point.set(x, 1 + (32 - x.length));
  point.set(y, 33 + (32 - y.length));
  return point;
}

/**
 * ECDH -> HMAC-SHA1 key. Matches WebCrypto deriveKey({HMAC,SHA-1,length:160}):
 * first 20 bytes of the shared point's X coordinate.
 */
export function deriveSharedSecret(secretKey: Uint8Array, peerPoint: Uint8Array): Uint8Array {
  const shared = p256.getSharedSecret(secretKey, peerPoint, false); // 0x04||X||Y
  return shared.slice(1, 21);
}

// ---------------------------------------------------------------------------
// TOTP (RFC 6238 over HMAC-SHA1, 6 digits, 30s step)
// ---------------------------------------------------------------------------

function counterToBuffer(counter: number): Uint8Array {
  const buf = new Uint8Array(8);
  new DataView(buf.buffer).setBigUint64(0, BigInt(counter));
  return buf;
}

function hotpTruncate(mac: Uint8Array, digits: number): string {
  const offset = mac[mac.length - 1]! & 0x0f;
  const binary =
    ((mac[offset]! & 0x7f) << 24) |
    ((mac[offset + 1]! & 0xff) << 16) |
    ((mac[offset + 2]! & 0xff) << 8) |
    (mac[offset + 3]! & 0xff);
  const mod = Math.pow(10, digits);
  return (binary % mod).toString().padStart(digits, '0');
}

export function generateTOTP(secret: Uint8Array, stepMs = 30000, digits = 6): string {
  const counter = Math.floor(Date.now() / stepMs);
  return hotpTruncate(hmac(sha1, secret, counterToBuffer(counter)), digits);
}

export function validateTOTP(
  code: string,
  secret: Uint8Array,
  stepMs = 30000,
  tolerance = 1,
): boolean {
  const currentStep = Math.floor(Date.now() / stepMs);
  for (let offset = -tolerance; offset <= tolerance; offset++) {
    const expected = hotpTruncate(hmac(sha1, secret, counterToBuffer(currentStep + offset)), 6);
    if (expected === code) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

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

export function saveKeyPair(kp: PairingKeyPair): void {
  try {
    localStorage.setItem(AUTH_STORAGE_KEY, bytesToHex(kp.secretKey));
  } catch {
    // storage unavailable
  }
}

export function loadKeyPair(): PairingKeyPair | null {
  try {
    const hex = localStorage.getItem(AUTH_STORAGE_KEY);
    if (!hex) return null;
    const secretKey = hexToBytes(hex);
    cachedKeyPair = { secretKey, publicKey: p256.getPublicKey(secretKey, false) };
    return cachedKeyPair;
  } catch {
    return null;
  }
}

export function clearKeyPair(): void {
  cachedKeyPair = null;
  try {
    localStorage.removeItem(AUTH_STORAGE_KEY);
  } catch {
    // storage unavailable
  }
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

export async function performPairingHandshake(
  hostUrl: string,
  sendPairRequest: (params: { publicKey: string }) => Promise<{ publicKey: string; totpIssuerUri: string }>,
  sendAuthRequest: (params: { code: string }) => Promise<{ token: string }>,
): Promise<string> {
  let kp = cachedKeyPair ?? loadKeyPair();
  if (!kp) {
    kp = generateKeyPair();
    saveKeyPair(kp);
  }

  const myPubStr = JSON.stringify(exportPublicKeyJwk(kp));

  const pairResp = await sendPairRequest({ publicKey: myPubStr });
  const peerPoint = importPeerPublicKey(JSON.parse(pairResp.publicKey) as JsonWebKey);
  const secret = deriveSharedSecret(kp.secretKey, peerPoint);

  const totpCode = generateTOTP(secret);
  const authResp = await sendAuthRequest({ code: totpCode });

  storeToken(authResp.token);

  return authResp.token;
}
