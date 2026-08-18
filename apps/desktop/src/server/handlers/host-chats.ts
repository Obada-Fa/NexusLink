// Load conversations that already exist on the PC (OpenCode, Cursor CLI/IDE,
// Antigravity) so the phone can open them instead of starting a blank chat.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { Database } from 'bun:sqlite';
import type { AgentEvent, AgentHostChat } from '@nexuslink/rpc-types';

export type HostChatDelta = Omit<AgentEvent, 'seq'>;

const LIST_CAP = 40;
const EVENT_CAP = 400;

export function cleanMessageText(raw: string): string {
  if (!raw || typeof raw !== 'string') return '';
  let text = raw;

  // 1. Strip entire auxiliary metadata and prompt wrapper blocks
  text = text
    .replace(/<timestamp>[\s\S]*?<\/timestamp>/gi, '')
    .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/gi, '')
    .replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/gi, '')
    .replace(/<SYSTEM_MESSAGE>[\s\S]*?<\/SYSTEM_MESSAGE>/gi, '')
    .replace(/<system_prompt>[\s\S]*?<\/system_prompt>/gi, '')
    .replace(/<skill-instruction>[\s\S]*?<\/skill-instruction>/gi, '')
    .replace(/<auto-slash-command>[\s\S]*?<\/auto-slash-command>/gi, '')
    .replace(/\[REDACTED\]/gi, '');

  // 2. Extract inner content from user query / request tags if present
  const userQueryMatch = text.match(/<user_query>([\s\S]*?)<\/user_query>/i)
    ?? text.match(/<USER_REQUEST>([\s\S]*?)<\/USER_REQUEST>/i)
    ?? text.match(/<user-request>([\s\S]*?)<\/user-request>/i);

  if (userQueryMatch && userQueryMatch[1]?.trim()) {
    text = userQueryMatch[1];
  } else {
    text = text.replace(/<\/?(?:user_query|USER_REQUEST|user-request|context|timestamp)>/gi, '');
  }

  // 3. Trim and normalize excessive blank lines
  text = text
    .replace(/\r\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  return text;
}

function clipTitle(text: string): string {
  const cleaned = cleanMessageText(text);
  const t = cleaned.replace(/\s+/g, ' ').trim();
  if (!t) return '';
  return t.length > 72 ? `${t.slice(0, 69)}…` : t;
}

function titleFromEvents(events: HostChatDelta[], fallback: string): string {
  const user = events.find((e) => e.kind === 'user' && e.text?.trim());
  return clipTitle(user?.text ?? '') || fallback;
}

function contentToText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => {
        if (typeof p === 'string') return p;
        const part = p as Record<string, unknown>;
        if (typeof part.text === 'string') return part.text;
        return '';
      })
      .join('');
  }
  return '';
}

function runCli(argv: string[], timeout = 12000): string {
  const proc = Bun.spawnSync(argv, {
    stdout: 'pipe',
    stderr: 'pipe',
    timeout,
    env: process.env as Record<string, string>,
  });
  return new TextDecoder().decode(proc.stdout ?? new Uint8Array()).trim();
}

function parseJson(text: string): unknown {
  const start = text.search(/[\[{]/);
  if (start < 0) return null;
  return JSON.parse(text.slice(start));
}

export function parseOpencodeExport(raw: unknown): HostChatDelta[] {
  const root = raw as Record<string, unknown> | null;
  const messages = Array.isArray(root?.messages) ? root.messages : [];
  const out: HostChatDelta[] = [];
  for (const msg of messages) {
    if (!msg || typeof msg !== 'object') continue;
    const rec = msg as Record<string, unknown>;
    const info = (rec.info as Record<string, unknown> | undefined) ?? rec;
    const role = String(info.role ?? '');
    const time = (info.time as Record<string, unknown> | undefined) ?? {};
    const ts = typeof time.created === 'number' ? time.created : Date.now();
    const parts = Array.isArray(rec.parts) ? rec.parts : [];
    const texts: string[] = [];
    for (const part of parts) {
      if (!part || typeof part !== 'object') continue;
      const p = part as Record<string, unknown>;
      const type = String(p.type ?? '');
      if (type === 'text' && typeof p.text === 'string' && p.text.trim()) {
        const cleaned = cleanMessageText(p.text);
        if (cleaned) texts.push(cleaned);
      } else if (type === 'reasoning' || type === 'thinking') {
        const think = typeof p.text === 'string' ? cleanMessageText(p.text) : '';
        if (think.trim()) out.push({ kind: 'thinking', text: think, ts });
      } else if (type === 'tool' || type === 'tool_use' || type === 'tool-invocation') {
        const state = (p.state as Record<string, unknown> | undefined) ?? {};
        const name = String(p.tool ?? p.name ?? 'tool');
        const refId = String(p.callID ?? p.id ?? '');
        const input = JSON.stringify(state.input ?? p.input ?? {}, null, 2).slice(0, 4000);
        const output = typeof state.output === 'string'
          ? state.output.slice(0, 4000)
          : JSON.stringify(state.output ?? p.output ?? {}, null, 2).slice(0, 4000);
        out.push({ kind: 'tool-start', toolName: name, toolInput: input, refId, ts });
        if (output && output !== '{}') {
          out.push({ kind: 'tool-end', toolName: name, toolOutput: output, refId, ts });
        }
      }
    }
    const text = texts.join('\n').trim();
    if (!text) continue;
    if (role === 'user') out.push({ kind: 'user', text, ts });
    else out.push({ kind: 'text', text, ts });
  }
  return out.slice(-EVENT_CAP);
}

export function parseCursorTranscriptLine(raw: unknown): HostChatDelta[] {
  if (!raw || typeof raw !== 'object') return [];
  const rec = raw as Record<string, unknown>;
  const role = String(rec.role ?? rec.type ?? '');
  const message = (rec.message as Record<string, unknown> | undefined) ?? rec;
  const ts = typeof rec.ts === 'number'
    ? rec.ts
    : typeof rec.createdAt === 'number'
      ? rec.createdAt
      : Date.now();
  const content = message.content ?? rec.content ?? rec.text;
  const out: HostChatDelta[] = [];
  if (Array.isArray(content)) {
    const texts: string[] = [];
    for (const part of content) {
      if (!part || typeof part !== 'object') {
        if (typeof part === 'string' && part.trim()) {
          const cleaned = cleanMessageText(part);
          if (cleaned) texts.push(cleaned);
        }
        continue;
      }
      const p = part as Record<string, unknown>;
      const type = String(p.type ?? '');
      if (type === 'text' && typeof p.text === 'string' && p.text.trim()) {
        const cleaned = cleanMessageText(p.text);
        if (cleaned) texts.push(cleaned);
      } else if (type === 'tool_use' || type === 'tool-call') {
        const name = String(p.name ?? 'tool');
        const refId = String(p.id ?? '');
        out.push({
          kind: 'tool-start',
          toolName: name,
          toolInput: JSON.stringify(p.input ?? p.arguments ?? {}, null, 2).slice(0, 4000),
          refId,
          ts,
        });
      } else if (type === 'tool_result') {
        out.push({
          kind: 'tool-end',
          refId: String(p.tool_use_id ?? p.id ?? ''),
          toolOutput: contentToText(p.content ?? p.output).slice(0, 4000),
          ts,
        });
      }
    }
    const text = texts.join('\n').trim();
    if (text) {
      out.unshift({
        kind: role === 'user' || role === 'human' ? 'user' : 'text',
        text,
        ts,
      });
    }
    return out;
  }
  const text = cleanMessageText(contentToText(content));
  if (!text) return [];
  if (role === 'user' || role === 'human') return [{ kind: 'user', text, ts }];
  if (role === 'assistant' || role === 'ai' || role === 'model') return [{ kind: 'text', text, ts }];
  return [];
}

export function parseCursorJsonl(text: string): HostChatDelta[] {
  const out: HostChatDelta[] = [];
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(...parseCursorTranscriptLine(JSON.parse(t)));
    } catch {
      // skip malformed lines
    }
  }
  return out.slice(-EVENT_CAP);
}

/** Pull UTF-8 strings out of protobuf length-delimited fields. */
export function extractProtobufStrings(buf: Uint8Array): string[] {
  const out: string[] = [];
  const walk = (bytes: Uint8Array, depth: number) => {
    if (depth > 6) return;
    let i = 0;
    while (i < bytes.length) {
      const tag = bytes[i++]!;
      const wire = tag & 7;
      if (wire === 2) {
        let len = 0;
        let shift = 0;
        while (i < bytes.length) {
          const b = bytes[i++]!;
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) === 0) break;
          shift += 7;
          if (shift > 28) return;
        }
        if (len < 0 || i + len > bytes.length) return;
        const slice = bytes.subarray(i, i + len);
        i += len;
        try {
          const s = new TextDecoder('utf-8', { fatal: true }).decode(slice);
          if (s.length >= 2 && /[\p{L}\p{N}]/u.test(s)) out.push(s);
        } catch {
          walk(slice, depth + 1);
        }
      } else if (wire === 0) {
        while (i < bytes.length && (bytes[i++]! & 0x80) !== 0) { /* varint */ }
      } else if (wire === 1) {
        i += 8;
      } else if (wire === 5) {
        i += 4;
      } else {
        return;
      }
    }
  };
  walk(buf, 0);
  return out;
}

export function parseAgyStepStrings(strings: string[]): HostChatDelta[] {
  const useful = strings.map(cleanMessageText).filter((t) => {
    if (t.length < 4 || t.length > 8000) return false;
    if (/^[0-9a-f-]{20,}$/i.test(t)) return false;
    if (/^[\x00-\x1f]+$/.test(t)) return false;
    return / /.test(t) || t.length >= 16;
  });
  if (!useful.length) return [];
  const out: HostChatDelta[] = [];
  useful.forEach((text, i) => {
    out.push({
      kind: i === 0 ? 'user' : 'text',
      text: text.trim(),
      ts: Date.now(),
    });
  });
  return out.slice(-EVENT_CAP);
}

export function parseAgyJsonl(text: string): HostChatDelta[] {
  const out: HostChatDelta[] = [];
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    try {
      const rec = JSON.parse(t) as Record<string, unknown>;
      const type = String(rec.type ?? '');
      const createdAt = typeof rec.created_at === 'string' ? Date.parse(rec.created_at) : Date.now();
      const ts = Number.isFinite(createdAt) ? createdAt : Date.now();

      if (type === 'USER_INPUT') {
        const raw = String(rec.content ?? '');
        const cleaned = cleanMessageText(raw);
        if (cleaned) {
          out.push({ kind: 'user', text: cleaned, ts });
        }
      } else if (type === 'PLANNER_RESPONSE' || type === 'MODEL_RESPONSE') {
        if (typeof rec.content === 'string' && rec.content.trim()) {
          const cleaned = cleanMessageText(rec.content);
          if (cleaned) {
            out.push({ kind: 'text', text: cleaned, ts });
          }
        }
        if (Array.isArray(rec.tool_calls)) {
          for (const tc of rec.tool_calls) {
            if (!tc || typeof tc !== 'object') continue;
            const name = String(tc.name ?? 'tool');
            const input = typeof tc.args === 'string'
              ? tc.args
              : JSON.stringify(tc.args ?? {}, null, 2);
            out.push({
              kind: 'tool-start',
              toolName: name,
              toolInput: input.slice(0, 4000),
              ts,
            });
          }
        }
      }
    } catch {
      // skip malformed lines
    }
  }
  return out.slice(-EVENT_CAP);
}

export function listOpencodeHostChats(bin: string): AgentHostChat[] {
  try {
    const raw = parseJson(runCli([bin, 'session', 'list', '--format', 'json', '-n', String(LIST_CAP)]));
    if (!Array.isArray(raw)) return [];
    return raw.slice(0, LIST_CAP).flatMap((row) => {
      if (!row || typeof row !== 'object') return [];
      const r = row as Record<string, unknown>;
      const id = String(r.id ?? '');
      if (!id) return [];
      const cwd = String(r.directory ?? r.cwd ?? '');
      const updated = typeof r.updated === 'number' ? r.updated : Date.now();
      const title = clipTitle(String(r.title ?? '')) || 'OpenCode session';
      return [{
        agent: 'opencode',
        hostChatId: id,
        title,
        cwd,
        updatedAt: updated,
        resumable: true,
        source: 'OpenCode',
      }];
    });
  } catch {
    return [];
  }
}

export function loadOpencodeHistory(bin: string, hostChatId: string): HostChatDelta[] {
  try {
    const raw = parseJson(runCli([bin, 'export', hostChatId], 20000));
    return parseOpencodeExport(raw);
  } catch {
    return [];
  }
}

function openReadonlyDb(path: string): Database | null {
  try {
    return new Database(path, { readonly: true, create: false });
  } catch {
    return null;
  }
}

export function listCursorCliHostChats(cursorBinInstalled: boolean): AgentHostChat[] {
  const root = join(homedir(), '.cursor', 'chats');
  if (!existsSync(root)) return [];
  const out: AgentHostChat[] = [];
  try {
    for (const workspace of readdirSync(root)) {
      const wsPath = join(root, workspace);
      let dirs: string[] = [];
      try {
        dirs = readdirSync(wsPath);
      } catch {
        continue;
      }
      for (const id of dirs) {
        const metaPath = join(wsPath, id, 'meta.json');
        if (!existsSync(metaPath)) continue;
        try {
          const meta = JSON.parse(readFileSync(metaPath, 'utf8')) as Record<string, unknown>;
          if (meta.hasConversation === false) continue;
          const cwd = String(meta.cwd ?? '');
          const updatedAt = typeof meta.updatedAtMs === 'number' ? meta.updatedAtMs : Date.now();
          const fallback = cwd ? basename(cwd) : 'Cursor CLI chat';
          out.push({
            agent: 'cursor',
            hostChatId: id,
            title: fallback,
            cwd,
            updatedAt,
            resumable: cursorBinInstalled,
            source: 'Cursor CLI',
          });
        } catch {
          // skip unreadable meta
        }
      }
    }
  } catch {
    return [];
  }
  return out
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, LIST_CAP);
}

export function loadCursorCliHistory(hostChatId: string): HostChatDelta[] {
  const root = join(homedir(), '.cursor', 'chats');
  if (!existsSync(root)) return [];
  try {
    for (const workspace of readdirSync(root)) {
      const dbPath = join(root, workspace, hostChatId, 'store.db');
      if (!existsSync(dbPath)) continue;
      const db = openReadonlyDb(dbPath);
      if (!db) return [];
      try {
        const rows = db.query('SELECT rowid, data FROM blobs ORDER BY rowid').all() as {
          rowid: number;
          data: Uint8Array | string;
        }[];
        const events: HostChatDelta[] = [];
        for (const row of rows) {
          const buf = typeof row.data === 'string' ? Buffer.from(row.data) : Buffer.from(row.data ?? []);
          if (!buf.length || (buf[0] !== 0x7b && buf[0] !== 0x5b)) continue;
          try {
            const parsed = JSON.parse(buf.toString('utf8'));
            events.push(...parseCursorTranscriptLine(parsed));
          } catch {
            // not a transcript blob
          }
        }
        return events.slice(-EVENT_CAP);
      } finally {
        db.close();
      }
    }
  } catch {
    return [];
  }
  return [];
}

export function listCursorIdeHostChats(): AgentHostChat[] {
  const root = join(homedir(), '.cursor', 'projects');
  if (!existsSync(root)) return [];
  const out: AgentHostChat[] = [];
  const seen = new Set<string>();
  try {
    for (const slug of readdirSync(root)) {
      const transcripts = join(root, slug, 'agent-transcripts');
      if (!existsSync(transcripts)) continue;
      let chats: string[] = [];
      try {
        chats = readdirSync(transcripts);
      } catch {
        continue;
      }

      // Infer project cwd from slug if possible
      let cwd = '';
      if (slug.startsWith('home-')) {
        const candidate = '/' + slug.replace(/-/g, '/');
        if (existsSync(candidate)) {
          cwd = candidate;
        } else {
          const parts = slug.split('-');
          let testPath = '/' + parts[0];
          for (let i = 1; i < parts.length; i++) {
            if (existsSync(`${testPath}/${parts[i]}`)) {
              testPath = `${testPath}/${parts[i]}`;
            } else if (existsSync(`${testPath}-${parts[i]}`)) {
              testPath = `${testPath}-${parts[i]}`;
            } else {
              testPath = `${testPath}/${parts[i]}`;
            }
          }
          if (existsSync(testPath)) cwd = testPath;
        }
      }

      for (const id of chats) {
        if (seen.has(id)) {
          const existing = out.find((x) => x.hostChatId === `ide:${id}`);
          if (existing && !existing.cwd && cwd) {
            existing.cwd = cwd;
          }
          continue;
        }
        const file = join(transcripts, id, `${id}.jsonl`);
        if (!existsSync(file)) continue;
        let updatedAt = Date.now();
        try {
          updatedAt = statSync(file).mtimeMs;
        } catch {
          // keep now
        }
        let title = 'Cursor IDE chat';
        try {
          const head = readFileSync(file, 'utf8').split('\n').slice(0, 30).join('\n');
          title = titleFromEvents(parseCursorJsonl(head), title);
        } catch {
          // keep fallback
        }
        seen.add(id);
        out.push({
          agent: 'cursor',
          hostChatId: `ide:${id}`,
          title,
          cwd,
          updatedAt,
          resumable: false,
          source: 'Cursor IDE',
        });
      }
    }
  } catch {
    return [];
  }
  return out
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, LIST_CAP);
}

export function loadCursorIdeHistory(hostChatId: string): HostChatDelta[] {
  const id = hostChatId.replace(/^ide:/, '');
  const root = join(homedir(), '.cursor', 'projects');
  if (!existsSync(root)) return [];
  try {
    for (const slug of readdirSync(root)) {
      const file = join(root, slug, 'agent-transcripts', id, `${id}.jsonl`);
      if (!existsSync(file)) continue;
      return parseCursorJsonl(readFileSync(file, 'utf8'));
    }
  } catch {
    return [];
  }
  return [];
}

export function listAgyHostChats(): AgentHostChat[] {
  const brainDir = join(homedir(), '.gemini', 'antigravity-cli', 'brain');
  const convDir = join(homedir(), '.gemini', 'antigravity-cli', 'conversations');
  const out: AgentHostChat[] = [];
  const seen = new Set<string>();

  if (existsSync(brainDir)) {
    try {
      for (const id of readdirSync(brainDir)) {
        const transcriptPath = join(brainDir, id, '.system_generated', 'logs', 'transcript.jsonl');
        if (!existsSync(transcriptPath)) continue;
        let updatedAt = Date.now();
        try {
          updatedAt = statSync(transcriptPath).mtimeMs;
        } catch {
          // keep now
        }
        let title = 'Antigravity conversation';
        try {
          const head = readFileSync(transcriptPath, 'utf8').split('\n').slice(0, 20).join('\n');
          title = titleFromEvents(parseAgyJsonl(head), title);
        } catch {
          // keep fallback
        }
        seen.add(id);
        out.push({
          agent: 'antigravity',
          hostChatId: id,
          title,
          cwd: '',
          updatedAt,
          resumable: true,
          source: 'Antigravity',
        });
      }
    } catch {
      // ignore
    }
  }

  if (existsSync(convDir)) {
    try {
      for (const name of readdirSync(convDir)) {
        if (!name.endsWith('.db') || name.includes('-wal') || name.includes('-shm')) continue;
        const id = name.replace(/\.db$/, '');
        if (seen.has(id)) continue;
        const path = join(convDir, name);
        let updatedAt = Date.now();
        try {
          updatedAt = statSync(path).mtimeMs;
        } catch {
          // keep now
        }
        out.push({
          agent: 'antigravity',
          hostChatId: id,
          title: 'Antigravity conversation',
          cwd: '',
          updatedAt,
          resumable: true,
          source: 'Antigravity',
        });
      }
    } catch {
      // ignore
    }
  }

  return out
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, LIST_CAP);
}

export function loadAgyHistory(hostChatId: string): HostChatDelta[] {
  const transcriptPath = join(homedir(), '.gemini', 'antigravity-cli', 'brain', hostChatId, '.system_generated', 'logs', 'transcript.jsonl');
  if (existsSync(transcriptPath)) {
    try {
      return parseAgyJsonl(readFileSync(transcriptPath, 'utf8'));
    } catch {
      // fallback to sqlite
    }
  }
  const path = join(homedir(), '.gemini', 'antigravity-cli', 'conversations', `${hostChatId}.db`);
  if (!existsSync(path)) return [];
  const db = openReadonlyDb(path);
  if (!db) return [];
  try {
    const rows = db.query('SELECT step_payload FROM steps ORDER BY idx').all() as {
      step_payload: Uint8Array | null;
    }[];
    const strings: string[] = [];
    for (const row of rows) {
      if (!row.step_payload) continue;
      strings.push(...extractProtobufStrings(Buffer.from(row.step_payload)));
    }
    return parseAgyStepStrings(strings);
  } catch {
    return [];
  } finally {
    db.close();
  }
}

export function loadHostChatHistory(agent: string, hostChatId: string, bin?: string | null): HostChatDelta[] {
  if (agent === 'opencode' && bin) return loadOpencodeHistory(bin, hostChatId);
  if (agent === 'cursor' && hostChatId.startsWith('ide:')) return loadCursorIdeHistory(hostChatId);
  if (agent === 'cursor') return loadCursorCliHistory(hostChatId);
  if (agent === 'antigravity') return loadAgyHistory(hostChatId);
  return [];
}
