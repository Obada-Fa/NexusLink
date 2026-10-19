import { Database } from 'bun:sqlite';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { ChatSummary, ChatQuery, ChatPage, FolderSummary, SourceHealth, ChatDelivery } from '../../rpc-types/src/chat';
import type { ChatHistoryEvent, ChatHistoryPage } from '../../rpc-types/src/chat';
import { identity } from './identity';

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
      CREATE TABLE IF NOT EXISTS operations(device TEXT,operation TEXT,args TEXT,state TEXT,body TEXT,PRIMARY KEY(device,operation));`);
    this.db.query("UPDATE operations SET state='uncertain',body=json_set(body,'$.state','uncertain','$.reason','Host restarted before delivery was confirmed') WHERE state='dispatching'").run();
    this.db.query("UPDATE operations SET state='rejected',body=json_set(body,'$.state','rejected','$.reason','Host restarted before dispatch') WHERE state='claimed'").run();
  }
  revision(): number { return (this.db.query("SELECT value FROM metadata WHERE key='revision'").get() as any).value; }
  get(id: string): ChatSummary | undefined {
    const row = this.db.query('SELECT body FROM chats WHERE id=COALESCE((SELECT id FROM aliases WHERE alias=?),?)').get(id,id) as any;
    return row ? JSON.parse(row.body) : undefined;
  }
  upsert(rows: ChatSummary[], source?: string, removeMissing = false): number {
    this.db.transaction(() => {
      let changed = false;
      for (let row of rows) {
        if (row.nativeId) {
          const old = this.db.query('SELECT id,body FROM chats WHERE source=? AND native=?').get(row.source,row.nativeId) as any;
          if (old) {
            const previous = JSON.parse(old.body) as ChatSummary;
            row = { ...row, agentSessionId: row.agentSessionId || previous.agentSessionId };
            if (row.managed === false && row.agentSessionId) row = { ...row, title:previous.title,preview:previous.preview,activityAt:previous.activityAt,folderId:previous.folderId,folderPath:previous.folderPath,folderName:previous.folderName };
            else if (!row.managed && previous.managed) row = { ...previous, activityAt:Math.max(previous.activityAt || 0,row.activityAt || 0) || null };
          }
        }
        if (row.agentSessionId) {
          const old = this.db.query('SELECT id FROM chats WHERE session=?').get(row.agentSessionId) as any;
          if (old && old.id !== row.id) {
            this.db.query('INSERT OR REPLACE INTO aliases VALUES (?,?)').run(old.id,row.id);
            this.db.query('DELETE FROM chats WHERE id=?').run(old.id);
            changed = true;
          }
        }
        const body = JSON.stringify(row);
        if ((this.db.query('SELECT body FROM chats WHERE id=?').get(row.id) as any)?.body === body) continue;
        const search = [row.title,row.preview,row.sourceName,row.folderPath].join(' ').toLowerCase();
        this.db.query('INSERT OR REPLACE INTO chats VALUES (?,?,?,?,?,?,?,?,?)').run(row.id,row.source,row.nativeId || null,row.agentSessionId || null,row.folderId,row.activityAt,row.archived ? 1 : 0,search,body);
        changed = true;
      }
      if (source && removeMissing) {
        const ids = new Set(rows.map(row => row.id));
        for (const old of this.db.query('SELECT id FROM chats WHERE source=? AND session IS NULL').all(source) as any[]) {
          if (!ids.has(old.id)) { this.db.query('DELETE FROM chats WHERE id=?').run(old.id); changed = true; }
        }
      }
      if (changed) this.db.query("UPDATE metadata SET value=value+1 WHERE key='revision'").run();
    })();
    return this.revision();
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
    const priority = `CASE WHEN json_extract(body,'$.execution')='needsReply' OR json_extract(body,'$.taskState') IN ('failed','interrupted') THEN 0 WHEN json_extract(body,'$.execution')='working' THEN 1 ELSE 2 END`;
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
  indexHistory(chat: string, fingerprint: string, raw: any[], reason?: string) {
    const events: ChatHistoryEvent[] = raw.map((event,index)=>({ ...event, seq:index+1, ts:Number.isFinite(event.ts)?event.ts:0, id:identity(chat,event.refId || String(index),event.kind,event.text || event.toolInput || ''),historical:event.kind === 'permission-request' }));
    const revision = identity('history',JSON.stringify(events.map(event=>event.id)));
    this.db.transaction(()=>{
      this.db.query('DELETE FROM history_events WHERE chat=?').run(chat);
      const insert=this.db.query('INSERT INTO history_events VALUES (?,?,?)');
      for(const original of events) {
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
    return {events,olderCursor:older?encode(first!):null,newerCursor:last!==undefined?encode(last):null,revision:index.revision,completeness:!events.length && index.reason?'unavailable':index.reason || events.some(e=>e.truncated)?'partial':'complete',reason:index.reason || undefined};
  }
}
