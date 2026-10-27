import { Database } from 'bun:sqlite';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { ChatSummary, ChatQuery, ChatPage, FolderSummary, SourceHealth, ChatDelivery } from '../../rpc-types/src/chat';
import type { ChatHistoryEvent, ChatHistoryPage } from '../../rpc-types/src/chat';
import { identity } from './identity';

const GENERIC_TITLE = /^(Claude Code chat|Codex conversation|Antigravity conversation|OpenCode conversation|OpenCode session|Cursor (IDE|CLI) chat|Host chat|New chat|Agent)$/;
/** Activity drift below this is not worth a library revision on its own. */
const ACTIVITY_SLACK_MS = 30_000;
/**
 * An inferred "needs you" (app metadata such as Claude Desktop's needs-action flag, or a
 * transcript heuristic) with no activity for this long is stale. A pending approval in a
 * session NexusLink is running is never aged out.
 */
export const STALE_ATTENTION_MS = 8 * 3_600_000;

export interface ChatUserState { ackAt: number | null; hidden: boolean }

export function needsAttention(row: ChatSummary): boolean {
  if (row.attentionCleared) return false;
  return row.execution === 'needsReply' || row.live?.state === 'waiting' || row.live?.state === 'failed' || ['failed', 'interrupted'].includes(row.taskState || '');
}

/**
 * The owner's choices on top of what the agent app reports: hidden chats leave the
 * Monitor; a chat marked done stops needing attention until it does something new.
 */
export function applyUserState(row: ChatSummary, state: ChatUserState | undefined, now: number, pendingApproval: boolean): ChatSummary {
  let out: ChatSummary = state?.hidden ? { ...row, archived: true } : row;
  if (!needsAttention(out)) return out;
  const at = out.activityAt || 0;
  const acknowledged = state?.ackAt != null && state.ackAt >= at;
  const stale = !pendingApproval && at > 0 && now - at > STALE_ATTENTION_MS;
  if (!acknowledged && !stale) return out;
  out = { ...out, attentionCleared: acknowledged ? 'acknowledged' : 'stale' };
  if (out.execution === 'needsReply') out.execution = 'idle';
  if (out.live && (out.live.state === 'waiting' || out.live.state === 'failed')) {
    const { waitingFor: _w, ...live } = out.live;
    out.live = { ...live, state: 'idle' };
  }
  return out;
}

/** SQL twin of needsAttention, for ordering and filtering pages. */
const ATTENTION_SQL = `json_extract(body,'$.attentionCleared') IS NULL AND (json_extract(body,'$.execution')='needsReply' OR json_extract(body,'$.taskState') IN ('failed','interrupted') OR json_extract(body,'$.live.state') IN ('waiting','failed'))`;

/**
 * A chat can be known twice: from the app's own files (scan part) and as a
 * NexusLink session the phone drove (owned part). The public row is composed:
 * the native transcript stays authoritative unless NexusLink is running a turn.
 */
export function composeChat(scan: ChatSummary | undefined, owned: ChatSummary | undefined): ChatSummary {
  if (!owned) return scan!;
  if (!scan) return owned;
  const nexusBusy = owned.execution === 'working' || owned.execution === 'needsReply';
  const composed: ChatSummary = {
    ...scan,
    agentSessionId: owned.agentSessionId,
    managed: owned.managed,
    title: GENERIC_TITLE.test(scan.title) && owned.title && !GENERIC_TITLE.test(owned.title) ? owned.title : scan.title,
    preview: scan.preview || owned.preview,
    folderId: scan.folderId ?? owned.folderId,
    folderPath: scan.folderPath ?? owned.folderPath,
    folderName: scan.folderId ? scan.folderName : owned.folderName,
    // NexusLink turns write the native transcript too, so its time is the truth;
    // attaching a session must not make an old chat jump to "now".
    activityAt: nexusBusy ? Math.max(scan.activityAt || 0, owned.activityAt || 0) || null : scan.activityAt ?? owned.activityAt,
    execution: nexusBusy ? owned.execution : scan.execution,
    taskState: nexusBusy ? owned.taskState : scan.taskState,
    activity: nexusBusy ? owned.activity : scan.activity,
    live: nexusBusy ? owned.live || scan.live : scan.live,
    capabilities: nexusBusy ? owned.capabilities : scan.capabilities,
  };
  for (const key of Object.keys(composed) as (keyof ChatSummary)[]) if (composed[key] === undefined) delete composed[key];
  return composed;
}

function comparable(row: ChatSummary) {
  const { activityAt: _a, live, ...rest } = row;
  if (!live) return JSON.stringify(rest);
  const { updatedAt: _u, steps: _s, ...liveRest } = live;
  return JSON.stringify({ ...rest, live: liveRest });
}
/** True when the phone should hear about this change (not just a newer mtime or token count). */
export function materialChange(before: ChatSummary | undefined, after: ChatSummary): boolean {
  if (!before) return true;
  if (comparable(before) !== comparable(after)) return true;
  return Math.abs((before.activityAt || 0) - (after.activityAt || 0)) >= ACTIVITY_SLACK_MS;
}

/** Constructed only inside the library worker in production. */
export class LibraryStorage {
  readonly db: Database;
  constructor(directory: string) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    this.db = new Database(join(directory, 'chat-library.sqlite'), { create: true });
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value INTEGER);
      INSERT OR IGNORE INTO metadata VALUES('revision',0);
      CREATE TABLE IF NOT EXISTS chats(id TEXT PRIMARY KEY,source TEXT,native TEXT,session TEXT,folder TEXT,activity INTEGER,archived INTEGER,search TEXT,body TEXT);
      CREATE INDEX IF NOT EXISTS chat_activity ON chats(activity DESC,id);
      CREATE INDEX IF NOT EXISTS chat_folder ON chats(folder,activity DESC);
      CREATE INDEX IF NOT EXISTS chat_native ON chats(source,native);
      CREATE TABLE IF NOT EXISTS aliases(alias TEXT PRIMARY KEY,id TEXT);
      CREATE TABLE IF NOT EXISTS health(source TEXT PRIMARY KEY,body TEXT);
      CREATE TABLE IF NOT EXISTS history_index(chat TEXT PRIMARY KEY,fingerprint TEXT,revision TEXT,reason TEXT);
      CREATE TABLE IF NOT EXISTS history_events(chat TEXT,seq INTEGER,body TEXT,PRIMARY KEY(chat,seq));
      CREATE TABLE IF NOT EXISTS operations(device TEXT,operation TEXT,args TEXT,state TEXT,body TEXT,PRIMARY KEY(device,operation));
      CREATE TABLE IF NOT EXISTS user_state(chat TEXT PRIMARY KEY,ack_at INTEGER,hidden INTEGER NOT NULL DEFAULT 0);`);
    const columns = new Set((this.db.query('PRAGMA table_info(chats)').all() as any[]).map(c => c.name));
    if (!columns.has('scan')) this.db.exec('ALTER TABLE chats ADD COLUMN scan TEXT');
    if (!columns.has('owned')) this.db.exec('ALTER TABLE chats ADD COLUMN owned TEXT');
    this.db.exec('CREATE INDEX IF NOT EXISTS chat_session ON chats(session)');
    this.db.query("UPDATE operations SET state='uncertain',body=json_set(body,'$.state','uncertain','$.reason','Host restarted before delivery was confirmed') WHERE state='dispatching'").run();
    this.db.query("UPDATE operations SET state='rejected',body=json_set(body,'$.state','rejected','$.reason','Host restarted before dispatch') WHERE state='claimed'").run();
  }
  revision(): number { return (this.db.query("SELECT value FROM metadata WHERE key='revision'").get() as any).value; }
  get(id: string): ChatSummary | undefined {
    const row = this.db.query('SELECT body FROM chats WHERE id=COALESCE((SELECT id FROM aliases WHERE alias=?),?)').get(id,id) as any;
    return row ? JSON.parse(row.body) : undefined;
  }
  private parts(record: any): { scan?: ChatSummary; owned?: ChatSummary } {
    if (!record) return {};
    if (record.scan || record.owned) return { scan: record.scan ? JSON.parse(record.scan) : undefined, owned: record.owned ? JSON.parse(record.owned) : undefined };
    // Rows written before parts existed: a session id means NexusLink owns it.
    const body = JSON.parse(record.body) as ChatSummary;
    return body.agentSessionId ? { owned: body } : { scan: body };
  }
  private userState(id: string): ChatUserState | undefined {
    const row = this.db.query('SELECT ack_at,hidden FROM user_state WHERE chat=?').get(id) as any;
    return row ? { ackAt: row.ack_at ?? null, hidden: row.hidden === 1 } : undefined;
  }
  private write(id: string, scan: ChatSummary | undefined, owned: ChatSummary | undefined, previousBody: ChatSummary | undefined, force = false): boolean {
    const row = applyUserState(composeChat(scan, owned), this.userState(id), Date.now(), owned?.execution === 'needsReply');
    const changed = materialChange(previousBody, row);
    if (!changed && !force) return false;
    const search = [row.title,row.preview,row.sourceName,row.folderPath].join(' ').toLowerCase();
    this.db.query('INSERT OR REPLACE INTO chats(id,source,native,session,folder,activity,archived,search,body,scan,owned) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
      .run(id,row.source,row.nativeId || null,row.agentSessionId || null,row.folderId,row.activityAt,row.archived ? 1 : 0,search,JSON.stringify(row),scan ? JSON.stringify(scan) : null,owned ? JSON.stringify(owned) : null);
    return changed;
  }
  /**
   * Rows from discovery (no agentSessionId) update the scan part; NexusLink
   * sessions update the owned part. Revisions only move on material changes.
   */
  upsert(rows: ChatSummary[], source?: string, removeMissing = false): number {
    this.db.transaction(() => {
      let changed = false;
      for (const row of rows) {
        const owned = !!row.agentSessionId;
        if (owned) {
          // The session learned its native identity: move it and keep an alias.
          const old = this.db.query('SELECT id,scan,owned,body FROM chats WHERE session=? AND id<>?').get(row.agentSessionId!,row.id) as any;
          if (old) {
            this.db.query('INSERT OR REPLACE INTO aliases VALUES (?,?)').run(old.id,row.id);
            const parts = this.parts(old);
            if (parts.scan) this.write(old.id, parts.scan, undefined, JSON.parse(old.body), true);
            else this.db.query('DELETE FROM chats WHERE id=?').run(old.id);
            changed = true;
          }
        }
        let record = this.db.query('SELECT id,scan,owned,body FROM chats WHERE id=?').get(row.id) as any;
        if (!record && row.nativeId) record = this.db.query('SELECT id,scan,owned,body FROM chats WHERE source=? AND native=?').get(row.source,row.nativeId) as any;
        const id = record?.id || row.id;
        const parts = this.parts(record);
        const scan = owned ? parts.scan : { ...row, id };
        const own = owned ? { ...row, id } : parts.owned;
        if (this.write(id, scan, own, record ? JSON.parse(record.body) : undefined)) changed = true;
      }
      if (source && removeMissing) {
        const ids = new Set(rows.map(row => row.id));
        for (const old of this.db.query('SELECT id,scan,owned,body FROM chats WHERE source=?').all(source) as any[]) {
          if (ids.has(old.id)) continue;
          const parts = this.parts(old);
          if (!parts.scan) continue;
          if (parts.owned) this.write(old.id, undefined, parts.owned, JSON.parse(old.body), true);
          else this.db.query('DELETE FROM chats WHERE id=?').run(old.id);
          changed = true;
        }
      }
      if (changed) this.db.query("UPDATE metadata SET value=value+1 WHERE key='revision'").run();
    })();
    return this.revision();
  }
  /** Mark a chat done (until it does something new) and/or hide it from the Monitor. */
  setState(id: string, change: { acknowledged?: boolean; hidden?: boolean }): { row: ChatSummary | undefined; revision: number } {
    const record = this.db.query('SELECT id,scan,owned,body FROM chats WHERE id=COALESCE((SELECT id FROM aliases WHERE alias=?),?)').get(id,id) as any;
    if (!record) throw new Error('Chat no longer exists in the library');
    const old = this.userState(record.id) ?? { ackAt: null, hidden: false };
    const next: ChatUserState = {
      ackAt: change.acknowledged === undefined ? old.ackAt : change.acknowledged ? Date.now() : null,
      hidden: change.hidden ?? old.hidden,
    };
    this.db.transaction(() => {
      this.db.query('INSERT OR REPLACE INTO user_state VALUES (?,?,?)').run(record.id, next.ackAt, next.hidden ? 1 : 0);
      const parts = this.parts(record);
      if (this.write(record.id, parts.scan, parts.owned, JSON.parse(record.body), true)) this.db.query("UPDATE metadata SET value=value+1 WHERE key='revision'").run();
    })();
    return { row: this.get(record.id), revision: this.revision() };
  }
  /** Re-evaluate attention that may have gone stale since the row was written. */
  decay(now = Date.now()): number {
    const rows = this.db.query(`SELECT id,scan,owned,body FROM chats WHERE ${ATTENTION_SQL} AND activity IS NOT NULL AND activity < ?`).all(now - STALE_ATTENTION_MS) as any[];
    if (!rows.length) return this.revision();
    this.db.transaction(() => {
      let changed = false;
      for (const record of rows) {
        const parts = this.parts(record);
        if (this.write(record.id, parts.scan, parts.owned, JSON.parse(record.body))) changed = true;
      }
      if (changed) this.db.query("UPDATE metadata SET value=value+1 WHERE key='revision'").run();
    })();
    return this.revision();
  }
  /** Chats worth polling every few seconds: recently written or currently working/waiting. */
  hot(since: number, limit = 40): Array<{ id: string; source: string; nativeId: string }> {
    return (this.db.query(`SELECT id,source,native FROM chats WHERE native IS NOT NULL AND archived=0 AND (activity>=? OR (json_extract(body,'$.execution') IN ('working','needsReply') AND activity>=?)) ORDER BY activity DESC LIMIT ?`)
      .all(since, since - 24 * 3_600_000, limit) as any[]).map(row => ({ id: row.id, source: row.source, nativeId: row.native }));
  }
  setHealth(health: SourceHealth) {
    const previous = (this.db.query('SELECT body FROM health WHERE source=?').get(health.source) as any)?.body;
    const old = previous ? JSON.parse(previous) : {};
    this.db.query('INSERT OR REPLACE INTO health VALUES (?,?)').run(health.source,JSON.stringify({...old,...health,reason:health.reason}));
  }
  health(): SourceHealth[] { return (this.db.query('SELECT body FROM health ORDER BY source').all() as any[]).map(row=>JSON.parse(row.body)); }
  page(query: ChatQuery & { sort?: string }, folders = false): ChatPage<ChatSummary | FolderSummary> {
    const limit = Math.min(100,Math.max(1,query.limit ?? 50));
    if (!Number.isInteger(limit)) throw new Error('Invalid page size');
    const revision = this.revision();
    const fingerprint = JSON.stringify([query.query || '',query.source || '',query.folderId,query.archived === true,query.sort || '',query.monitorFilter || 'all',folders]);
    let offset = 0;
    if (query.cursor) {
      let cursor: any;
      try { cursor = JSON.parse(Buffer.from(query.cursor,'base64url').toString()); } catch { throw new Error('Invalid library cursor'); }
      if (cursor.revision !== revision || cursor.fingerprint !== fingerprint) return { items: [], nextCursor: null, revision, restart: true, sources: this.health() };
      if (!Number.isSafeInteger(cursor.offset) || cursor.offset < 0) throw new Error('Invalid library cursor');
      offset = cursor.offset;
    }
    const where = ['archived=?']; const args: any[] = [query.archived ? 1 : 0];
    if (query.source) { where.push('source=?'); args.push(query.source); }
    if (query.folderId !== undefined) { where.push('folder IS ?'); args.push(query.folderId); }
    if (query.query) { where.push('instr(search,?)>0'); args.push(query.query.toLowerCase()); }
    if (query.monitorFilter && !['all','running','attention','recent'].includes(query.monitorFilter)) throw new Error('Invalid monitor filter');
    const priority = `CASE WHEN ${ATTENTION_SQL} THEN 0 WHEN json_extract(body,'$.execution')='working' THEN 1 ELSE 2 END`;
    if (!folders && query.monitorFilter && query.monitorFilter !== 'all') {
      where.push(`(${priority})=?`);
      args.push(query.monitorFilter === 'attention' ? 0 : query.monitorFilter === 'running' ? 1 : 2);
    }
    const order = query.sort === 'monitor' ? `${priority},activity DESC,id` : 'activity DESC,id';
    let items: any[];
    if (folders) {
      items = (this.db.query(`SELECT body,COUNT(*) AS count,MAX(activity) AS activity FROM chats WHERE ${where.join(' AND ')} GROUP BY folder`).all(...args) as any[]).map(row=>{
        const chat = JSON.parse(row.body);
        return { id: chat.folderId, name: chat.folderName, path: chat.folderPath, count: row.count, activityAt: row.activity, latestTitle: chat.title };
      });
      items.sort(query.sort === 'name' ? (a,b)=>a.name.localeCompare(b.name)||String(a.id).localeCompare(String(b.id)) : (a,b)=>(b.activityAt||0)-(a.activityAt||0)||String(a.id).localeCompare(String(b.id)));
      items = items.slice(offset,offset+limit+1);
    } else items = (this.db.query(`SELECT body FROM chats WHERE ${where.join(' AND ')} ORDER BY ${order} LIMIT ? OFFSET ?`).all(...args,limit+1,offset) as any[]).map(row=>JSON.parse(row.body));
    const hasMore = items.length > limit;
    return { items: items.slice(0,limit), nextCursor: hasMore ? Buffer.from(JSON.stringify({revision,fingerprint,offset:offset+limit})).toString('base64url') : null, revision, sources: this.health() };
  }
  operation(device: string, operationId: string): ChatDelivery | null {
    const row = this.db.query('SELECT body FROM operations WHERE device=? AND operation=?').get(device,operationId) as any;
    return row ? JSON.parse(row.body) : null;
  }
  claim(device: string, operationId: string, args: string): ChatDelivery & { fresh: boolean } {
    const old = this.db.query('SELECT args,body FROM operations WHERE device=? AND operation=?').get(device,operationId) as any;
    if (old) {
      if (old.args !== args) throw new Error('Operation ID reused with different arguments');
      return {...JSON.parse(old.body),fresh:false};
    }
    const body: ChatDelivery = {operationId,state:'claimed'};
    this.db.query('INSERT INTO operations VALUES (?,?,?,?,?)').run(device,operationId,args,body.state,JSON.stringify(body));
    return {...body,fresh:true};
  }
  finish(device: string, body: ChatDelivery) {
    this.db.query('UPDATE operations SET state=?,body=? WHERE device=? AND operation=?').run(body.state,JSON.stringify(body),device,body.operationId);
    return body;
  }
  close() { this.db.close(); }
  historyFingerprint(chat: string): string | null {
    return (this.db.query('SELECT fingerprint FROM history_index WHERE chat=?').get(chat) as any)?.fingerprint ?? null;
  }
  /**
   * Re-indexes a native transcript. When the new events only extend the old
   * ones (the common case for a chat that keeps working), the revision and all
   * cursors stay valid and only the new tail is written.
   */
  indexHistory(chat: string, fingerprint: string, raw: any[], reason?: string) {
    const events: ChatHistoryEvent[] = raw.map((event,index)=>({ ...event, seq:index+1, ts:Number.isFinite(event.ts)?event.ts:0, id:identity(chat,event.refId || String(index),event.kind,event.text || event.toolInput || ''),historical:event.kind === 'permission-request' }));
    const old = this.db.query('SELECT revision FROM history_index WHERE chat=?').get(chat) as any;
    const count = (this.db.query('SELECT COUNT(*) AS n, MAX(seq) AS last FROM history_events WHERE chat=?').get(chat) as any);
    let start = 0; let revision: string;
    const sameAt = (seq: number) => {
      if (!seq) return true;
      const body = (this.db.query('SELECT body FROM history_events WHERE chat=? AND seq=?').get(chat,seq) as any)?.body;
      return !!body && JSON.parse(body).id === events[seq - 1]?.id;
    };
    if (old && count.n > 0 && count.n === count.last && count.n <= events.length && sameAt(1) && sameAt(count.n) && sameAt(Math.ceil(count.n / 2))) {
      start = count.n; revision = old.revision;
    } else revision = identity('history',JSON.stringify(events.map(event=>event.id)));
    this.db.transaction(()=>{
      if (!start) this.db.query('DELETE FROM history_events WHERE chat=?').run(chat);
      const insert=this.db.query('INSERT OR REPLACE INTO history_events VALUES (?,?,?)');
      for(const original of events.slice(start)) {
        const event={...original};
        for(const key of ['text','toolInput','toolOutput'] as const) if(event[key] && Buffer.byteLength(event[key]!)>65536) {event[key]=Buffer.from(event[key]!).subarray(0,65536).toString('utf8');event.truncated=true;}
        insert.run(chat,event.seq,JSON.stringify(event));
      }
      this.db.query('INSERT OR REPLACE INTO history_index VALUES (?,?,?,?)').run(chat,fingerprint,revision,reason || null);
    })();
  }
  historyPage(chat: string, params: { olderCursor?: string; newerCursor?: string; limit?: number }): ChatHistoryPage {
    const index=this.db.query('SELECT revision,reason FROM history_index WHERE chat=?').get(chat) as any;
    if(!index) return {events:[],olderCursor:null,newerCursor:null,revision:'0',completeness:'unavailable',reason:'This app’s history has not been indexed yet.'};
    const limit=Math.min(100,Math.max(1,params.limit ?? 100));
    let seq=Number.MAX_SAFE_INTEGER;
    const cursor=params.olderCursor || params.newerCursor;
    if(cursor) {
      let value:any;
      try{value=JSON.parse(Buffer.from(cursor,'base64url').toString());}catch{throw new Error('Invalid history cursor');}
      if(value.chat!==chat || value.revision!==index.revision) return {events:[],olderCursor:null,newerCursor:null,revision:index.revision,completeness:'partial',restart:true};
      if(!Number.isSafeInteger(value.seq)||value.seq<0)throw new Error('Invalid history cursor');seq=value.seq;
    }
    const newer=!!params.newerCursor;
    const rows=this.db.query(`SELECT body FROM history_events WHERE chat=? AND seq${newer?'>':'<'}? ORDER BY seq ${newer?'ASC':'DESC'} LIMIT ?`).all(chat,seq,limit) as any[];
    let events:ChatHistoryEvent[]=rows.map(row=>JSON.parse(row.body));
    if(!newer)events.reverse();
    let bytes=0;
    const selected:ChatHistoryEvent[]=[];
    // Keep the newest events for backwards reads and the oldest for forward reads.
    for(const event of newer?events:[...events].reverse()) {
      const size=Buffer.byteLength(JSON.stringify(event));
      if(selected.length && bytes+size>500*1024)break;
      selected.push(event);bytes+=size;
    }
    events=newer?selected:selected.reverse();
    const encode=(seq:number)=>Buffer.from(JSON.stringify({chat,revision:index.revision,seq})).toString('base64url');
    const first=events[0]?.seq; const last=events.at(-1)?.seq;
    const older=first!==undefined && !!this.db.query('SELECT seq FROM history_events WHERE chat=? AND seq<? LIMIT 1').get(chat,first);
    // An empty forward read keeps the caller's position so it can poll again.
    const newerCursor=last!==undefined?encode(last):newer?encode(seq):null;
    return {events,olderCursor:older?encode(first!):null,newerCursor,revision:index.revision,completeness:!events.length && index.reason?'unavailable':index.reason || events.some(e=>e.truncated)?'partial':'complete',reason:index.reason || undefined};
  }
}
