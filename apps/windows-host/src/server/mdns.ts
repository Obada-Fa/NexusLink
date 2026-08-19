// Minimal mDNS responder advertising _nexuslink._tcp.local so the Flutter app
// can discover the host with zero typing. Pure Bun (node:dgram multicast) — no
// Avahi dependency, works when packaged. Answers PTR/SRV/TXT/A queries for our
// service and hostname; records are also stuffed into the additional section so
// one-shot resolvers get everything in a single round trip.

import { createSocket, type Socket } from 'node:dgram';
import { networkInterfaces, hostname } from 'node:os';

const MDNS_ADDR = '224.0.0.251';
const MDNS_PORT = 5353;

const SERVICE_TYPE = '_nexuslink._tcp.local';
const TTL = 120;

const TYPE_A = 1;
const TYPE_PTR = 12;
const TYPE_TXT = 16;
const TYPE_SRV = 33;
const TYPE_ANY = 255;
const CLASS_IN = 1;
/** cache-flush bit for authoritative unique records */
const CLASS_IN_FLUSH = 0x8001;

let socket: Socket | null = null;

function lanIPv4s(): string[] {
  const out: string[] = [];
  const ifs = networkInterfaces();
  for (const list of Object.values(ifs)) {
    for (const info of list ?? []) {
      if (info.family === 'IPv4' && !info.internal) out.push(info.address);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// DNS wire encoding (no compression — mDNS peers accept uncompressed names)
// ---------------------------------------------------------------------------

function encodeName(name: string): Buffer {
  const parts = name.split('.').filter(Boolean);
  const chunks: Buffer[] = [];
  for (const p of parts) {
    const b = Buffer.from(p, 'utf8');
    chunks.push(Buffer.from([b.length]), b);
  }
  chunks.push(Buffer.from([0]));
  return Buffer.concat(chunks);
}

interface Record {
  name: string;
  type: number;
  cls: number;
  data: Buffer;
}

function encodeRecord(r: Record): Buffer {
  const name = encodeName(r.name);
  const head = Buffer.allocUnsafe(10);
  head.writeUInt16BE(r.type, 0);
  head.writeUInt16BE(r.cls, 2);
  head.writeUInt32BE(TTL, 4);
  head.writeUInt16BE(r.data.length, 8);
  return Buffer.concat([name, head, r.data]);
}

function ptrData(target: string): Buffer {
  return encodeName(target);
}

function srvData(port: number, target: string): Buffer {
  const head = Buffer.allocUnsafe(6);
  head.writeUInt16BE(0, 0); // priority
  head.writeUInt16BE(0, 2); // weight
  head.writeUInt16BE(port, 4);
  return Buffer.concat([head, encodeName(target)]);
}

function txtData(entries: string[]): Buffer {
  const chunks: Buffer[] = [];
  for (const e of entries) {
    const b = Buffer.from(e, 'utf8');
    chunks.push(Buffer.from([b.length]), b);
  }
  return chunks.length ? Buffer.concat(chunks) : Buffer.from([0]);
}

function aData(ip: string): Buffer {
  return Buffer.from(ip.split('.').map((n) => parseInt(n, 10)));
}

function buildResponse(answers: Record[], additionals: Record[]): Buffer {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0); // id 0 for mDNS
  header.writeUInt16BE(0x8400, 2); // QR=1 (response), AA=1
  header.writeUInt16BE(0, 4); // qdcount
  header.writeUInt16BE(answers.length, 6);
  header.writeUInt16BE(0, 8); // nscount
  header.writeUInt16BE(additionals.length, 10);
  return Buffer.concat([header, ...answers.map(encodeRecord), ...additionals.map(encodeRecord)]);
}

// ---------------------------------------------------------------------------
// Query parsing (names may use compression pointers — follow them)
// ---------------------------------------------------------------------------

function decodeName(buf: Buffer, offset: number): { name: string; next: number } {
  const labels: string[] = [];
  let pos = offset;
  let jumped = false;
  let next = offset;
  let hops = 0;
  while (pos < buf.length && hops < 16) {
    const len = buf[pos]!;
    if (len === 0) {
      if (!jumped) next = pos + 1;
      break;
    }
    if ((len & 0xc0) === 0xc0) {
      if (pos + 1 >= buf.length) break;
      if (!jumped) next = pos + 2;
      pos = ((len & 0x3f) << 8) | buf[pos + 1]!;
      jumped = true;
      hops++;
      continue;
    }
    labels.push(buf.subarray(pos + 1, pos + 1 + len).toString('utf8'));
    pos += 1 + len;
  }
  return { name: labels.join('.'), next };
}

interface Question {
  name: string;
  type: number;
}

function parseQuestions(buf: Buffer): Question[] {
  if (buf.length < 12) return [];
  const flags = buf.readUInt16BE(2);
  if ((flags & 0x8000) !== 0) return []; // a response, not a query
  const qdcount = buf.readUInt16BE(4);
  const questions: Question[] = [];
  let pos = 12;
  for (let i = 0; i < qdcount && pos < buf.length; i++) {
    const { name, next } = decodeName(buf, pos);
    if (next + 4 > buf.length) break;
    questions.push({ name: name.toLowerCase(), type: buf.readUInt16BE(next) });
    pos = next + 4;
  }
  return questions;
}

// ---------------------------------------------------------------------------
// Responder
// ---------------------------------------------------------------------------

export function startMdns(port: number): void {
  const host = hostname().replace(/\.local$/i, '');
  const hostLocal = `${host}.local`;
  const instance = `NexusLink on ${host}.${SERVICE_TYPE}`;

  const records = () => {
    const ips = lanIPv4s();
    const aRecords: Record[] = ips.map((ip) => ({
      name: hostLocal,
      type: TYPE_A,
      cls: CLASS_IN_FLUSH,
      data: aData(ip),
    }));
    const srv: Record = {
      name: instance,
      type: TYPE_SRV,
      cls: CLASS_IN_FLUSH,
      data: srvData(port, hostLocal),
    };
    const txt: Record = {
      name: instance,
      type: TYPE_TXT,
      cls: CLASS_IN_FLUSH,
      data: txtData(['path=/rpc', 'v=1']),
    };
    const ptr: Record = {
      name: SERVICE_TYPE,
      type: TYPE_PTR,
      cls: CLASS_IN,
      data: ptrData(instance),
    };
    return { ptr, srv, txt, aRecords };
  };

  try {
    socket = createSocket({ type: 'udp4', reuseAddr: true });

    socket.on('message', (msg, rinfo) => {
      let questions: Question[];
      try {
        questions = parseQuestions(msg);
      } catch {
        return;
      }
      if (questions.length === 0) return;

      const { ptr, srv, txt, aRecords } = records();
      const answers: Record[] = [];
      const additionals: Record[] = [];

      for (const q of questions) {
        const wantsAny = q.type === TYPE_ANY;
        if (q.name === SERVICE_TYPE.toLowerCase() && (q.type === TYPE_PTR || wantsAny)) {
          answers.push(ptr);
          additionals.push(srv, txt, ...aRecords);
        } else if (q.name === instance.toLowerCase()) {
          if (q.type === TYPE_SRV || wantsAny) answers.push(srv);
          if (q.type === TYPE_TXT || wantsAny) answers.push(txt);
          additionals.push(...aRecords);
        } else if (q.name === hostLocal.toLowerCase() && (q.type === TYPE_A || wantsAny)) {
          answers.push(...aRecords);
        }
      }
      if (answers.length === 0) return;

      const resp = buildResponse(answers, additionals);
      // Reply via multicast (standard for shared records) so caches converge.
      socket?.send(resp, MDNS_PORT, MDNS_ADDR, () => {});
      // Unicast copy for one-shot resolvers that asked from an ephemeral port.
      if (rinfo.port !== MDNS_PORT) {
        socket?.send(resp, rinfo.port, rinfo.address, () => {});
      }
    });

    socket.on('error', () => {
      // mDNS is best-effort; QR/manual connect remain available.
      try {
        socket?.close();
      } catch {
        /* ignore */
      }
      socket = null;
    });

    socket.bind(MDNS_PORT, () => {
      try {
        socket?.addMembership(MDNS_ADDR);
        socket?.setMulticastTTL(255);
        // Unsolicited announce (RFC 6762 §8.3) so already-listening browsers see us.
        const { ptr, srv, txt, aRecords } = records();
        const announce = buildResponse([ptr, srv, txt, ...aRecords], []);
        socket?.send(announce, MDNS_PORT, MDNS_ADDR, () => {});
        console.log(`[mdns] advertising ${instance} on :${port}`);
      } catch {
        // interface without multicast — non-fatal
      }
    });
  } catch {
    socket = null;
  }
}

export function stopMdns(): void {
  try {
    socket?.close();
  } catch {
    /* ignore */
  }
  socket = null;
}
