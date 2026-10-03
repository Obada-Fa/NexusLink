import { Database } from 'bun:sqlite';
import { mkdirSync, existsSync, readFileSync, copyFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
let db: Database;
self.onmessage = (message: MessageEvent) => {
  const {id, op, data} = message.data;
  try {
    let result: any = null;
    if(op==='init') {
      mkdirSync(data.directory,{recursive:true,mode:0o700});
      db=new Database(join(data.directory,'agents.sqlite'),{create:true});
      chmodSync(join(data.directory,'agents.sqlite'),0o600);
      db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, info TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(task TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(task,seq));
        CREATE TABLE IF NOT EXISTS activity(id INTEGER PRIMARY KEY AUTOINCREMENT, task TEXT, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS approvals(task TEXT NOT NULL, request TEXT NOT NULL, body TEXT NOT NULL, state TEXT NOT NULL, PRIMARY KEY(task,request));
        CREATE TABLE IF NOT EXISTS turns(task TEXT NOT NULL, turn TEXT NOT NULL, state TEXT NOT NULL, updated INTEGER NOT NULL, PRIMARY KEY(task,turn));`);
      const legacy=data.legacy || join(homedir(),'.cache','nexuslink','agent_sessions.json');
      if(!db.query("SELECT value FROM metadata WHERE key='migration'").get()) {
        if(existsSync(legacy)) {
          const rows=JSON.parse(readFileSync(legacy,'utf8'));
          if(!Array.isArray(rows)) throw new Error('Legacy agent store must be an array; migration was not applied.');
          if(!existsSync(legacy+'.pre-sqlite.bak')) copyFileSync(legacy,legacy+'.pre-sqlite.bak');
          db.transaction(()=>{for(const row of rows) {
            if(!row.info?.agentSessionId) continue;
            db.query('INSERT OR IGNORE INTO tasks VALUES (?,?)').run(row.info.agentSessionId,JSON.stringify(row.info));
            for(const ev of row.history || []) if(Number.isInteger(ev.seq)) db.query('INSERT OR IGNORE INTO events VALUES (?,?,?)').run(row.info.agentSessionId,ev.seq,JSON.stringify(ev));
          } db.query('INSERT INTO metadata VALUES (?,?)').run('migration','1');})();
        } else db.query('INSERT INTO metadata VALUES (?,?)').run('migration','1');
      }
      db.transaction(()=>{
        for(const row of db.query('SELECT * FROM tasks').all() as any[]) {
          const info=JSON.parse(row.info);
          if(info.busy || info.taskState==='waiting' || info.taskState==='running') {
            info.busy=false;info.taskState='interrupted';
            db.query('UPDATE tasks SET info=? WHERE id=?').run(JSON.stringify(info),row.id);
          }
        }
        db.query("UPDATE approvals SET state='expired' WHERE state='pending'").run();
        db.query("UPDATE turns SET state='interrupted' WHERE state='running'").run();
      })();
      result=(db.query('SELECT * FROM tasks').all() as any[]).map(row=>({info:JSON.parse(row.info),history:(db.query('SELECT body FROM events WHERE task=? ORDER BY seq DESC LIMIT 1000').all(row.id) as any[]).reverse().map(e=>JSON.parse(e.body))}));
    } else if(op==='batch') {
      db.transaction(()=>{for(const entry of data) {
        if(entry.delete) { db.query('DELETE FROM tasks WHERE id=?').run(entry.delete); db.query('DELETE FROM events WHERE task=?').run(entry.delete); db.query('DELETE FROM approvals WHERE task=?').run(entry.delete); db.query('DELETE FROM turns WHERE task=?').run(entry.delete); continue; }
        const task=entry.info.agentSessionId;
        db.query('INSERT OR REPLACE INTO tasks VALUES (?,?)').run(task,JSON.stringify(entry.info));
        for(const ev of entry.events || []) {
          const change=db.query('INSERT OR IGNORE INTO events VALUES (?,?,?)').run(task,ev.seq,JSON.stringify(ev));
          if(change.changes && ev.kind==='permission-request' && ev.refId) db.query('INSERT OR REPLACE INTO approvals VALUES (?,?,?,?)').run(task,ev.refId,JSON.stringify(ev),'pending');
          if(change.changes && ev.kind==='status' && ev.refId && ev.text?.startsWith('Approval ')) db.query('UPDATE approvals SET state=? WHERE task=? AND request=?').run(ev.text.slice(9).replace('.',''),task,ev.refId);
          if(change.changes && ev.turnId) {
            const state=ev.kind==='result'?'completed':ev.kind==='error'?'failed':ev.kind==='status' && ev.text==='cancelled'?'canceled':'running';
            db.query("INSERT INTO turns VALUES (?,?,?,?) ON CONFLICT(task,turn) DO UPDATE SET state=CASE WHEN excluded.state='running' AND turns.state!='running' THEN turns.state ELSE excluded.state END,updated=excluded.updated").run(task,ev.turnId,state,ev.ts);
          }
          if(change.changes && ['result','error','permission-request','status'].includes(ev.kind)) db.query('INSERT INTO activity(task,body) VALUES (?,?)').run(task,JSON.stringify({type:'agent-event',agentSessionId:task,event:{seq:ev.seq,ts:ev.ts,kind:ev.kind,turnId:ev.turnId,requestId:ev.requestId,toolName:ev.toolName}}));
        }
      } db.exec('DELETE FROM activity WHERE id < (SELECT COALESCE(MAX(id),0)-2000 FROM activity)');})();
      result={ok:true};
    } else if(op==='history') {
      const limit=Math.min(200,Math.max(1,data.limit || 100));
      const after=data.afterSeq;
      const rows=after!==undefined
        ? db.query('SELECT body FROM events WHERE task=? AND seq>? ORDER BY seq LIMIT ?').all(data.task,after,limit)
        : db.query('SELECT body FROM events WHERE task=? AND seq<? ORDER BY seq DESC LIMIT ?').all(data.task,data.beforeSeq || Number.MAX_SAFE_INTEGER,limit);
      const events=(rows as any[]).map(row=>JSON.parse(row.body)); if(after===undefined) events.reverse();
      result={events,oldestSeq:events[0]?.seq || null,latestSeq:events.at(-1)?.seq || null,hasMore:rows.length===limit};
    } else if(op==='activity') {
      result={events:(db.query('SELECT id, body FROM activity WHERE id>? ORDER BY id LIMIT 200').all(data.cursor || 0) as any[]).map(row=>({cursor:row.id,...JSON.parse(row.body)})),cursor:(db.query('SELECT COALESCE(MAX(id),0) AS id FROM activity').get() as any).id};
    }
    self.postMessage({id,result});
  } catch(error) { self.postMessage({id,error:error instanceof Error?error.message:'Storage failure'}); }
};
