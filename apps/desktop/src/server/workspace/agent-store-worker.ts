import { Database } from 'bun:sqlite';
import { mkdirSync, existsSync, readFileSync, copyFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
let db: Database;
function boundedUtf8(value:string,maxBytes:number):string {
  let out='';let bytes=0;
  for(const char of value){const size=Buffer.byteLength(char,'utf8');if(bytes+size>maxBytes)break;out+=char;bytes+=size;}
  return out;
}
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
        CREATE TABLE IF NOT EXISTS activity_v2(cursor INTEGER PRIMARY KEY AUTOINCREMENT, task TEXT NOT NULL, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS activity_actions(device TEXT NOT NULL, operation TEXT NOT NULL, args TEXT NOT NULL, state TEXT NOT NULL, reason TEXT, updated INTEGER NOT NULL, PRIMARY KEY(device,operation));
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
        db.query("UPDATE activity_actions SET state='rejected',reason='Host restarted before dispatch' WHERE state='claimed'").run();
        db.query("UPDATE activity_actions SET state='uncertain',reason='Host restarted during dispatch' WHERE state='dispatching'").run();
      })();
      result=(db.query('SELECT * FROM tasks').all() as any[]).map(row=>({info:JSON.parse(row.info),history:(db.query('SELECT body FROM events WHERE task=? ORDER BY seq DESC LIMIT 1000').all(row.id) as any[]).reverse().map(e=>JSON.parse(e.body))}));
    } else if(op==='batch') {
      const activity:any[]=[];
      db.transaction(()=>{for(const entry of data.entries) {
        if(entry.delete) { db.query('DELETE FROM tasks WHERE id=?').run(entry.delete); db.query('DELETE FROM events WHERE task=?').run(entry.delete); db.query('DELETE FROM approvals WHERE task=?').run(entry.delete); db.query('DELETE FROM turns WHERE task=?').run(entry.delete); continue; }
        const task=entry.info.agentSessionId;
        db.query('INSERT OR REPLACE INTO tasks VALUES (?,?)').run(task,JSON.stringify(entry.info));
        for(const ev of entry.events || []) {
          const change=db.query('INSERT OR IGNORE INTO events VALUES (?,?,?)').run(task,ev.seq,JSON.stringify(ev));
          if(change.changes && ev.kind==='permission-request' && ev.refId) db.query('INSERT OR REPLACE INTO approvals VALUES (?,?,?,?)').run(task,ev.refId,JSON.stringify(ev),'pending');
          if(change.changes && ev.kind==='status' && ev.refId && ev.approvalOutcome) db.query('UPDATE approvals SET state=? WHERE task=? AND request=?').run(ev.approvalOutcome,task,ev.refId);
          if(change.changes && ev.turnId) {
            const state=ev.kind==='result'?'completed':ev.kind==='error'?'failed':ev.kind==='status' && ev.text==='cancelled'?'canceled':'running';
            db.query("INSERT INTO turns VALUES (?,?,?,?) ON CONFLICT(task,turn) DO UPDATE SET state=CASE WHEN excluded.state='running' AND turns.state!='running' THEN turns.state ELSE excluded.state END,updated=excluded.updated").run(task,ev.turnId,state,ev.ts);
          }
          if(change.changes && ['result','error','permission-request','status'].includes(ev.kind)) db.query('INSERT INTO activity(task,body) VALUES (?,?)').run(task,JSON.stringify({type:'agent-event',agentSessionId:task,event:{seq:ev.seq,ts:ev.ts,kind:ev.kind,turnId:ev.turnId,requestId:ev.requestId,toolName:ev.toolName}}));
          if(change.changes && ['result','error','permission-request','status','user'].includes(ev.kind)) {
            const kind=ev.kind==='result'?'completed':ev.kind==='error'?'failed':ev.kind==='permission-request'?'approval-requested':ev.approvalOutcome?'approval-resolved':'task-updated';
            const requestPreview=typeof ev.toolInput==='string'?ev.toolInput:'';
            let structuredRequest=false;
            try {const parsed=JSON.parse(requestPreview);structuredRequest=!!parsed && typeof parsed==='object' && !Array.isArray(parsed) && Object.keys(parsed).length>0;} catch {}
            const previewComplete=kind==='approval-requested' && structuredRequest && Buffer.byteLength(requestPreview,'utf8')<=2048;
            const preview=boundedUtf8(kind==='approval-requested'?requestPreview:ev.text || entry.info.preview || '',2048);
            const availableActions=kind==='approval-requested'?(previewComplete?['approve','deny','open']:['deny','open']):['completed','failed'].includes(kind)?['reply','open']:['open'];
            const record={ts:ev.ts,hostId:data.hostId,agentSessionId:task,turnId:ev.turnId,eventSeq:ev.seq,kind,requestId:ev.refId,approvalOutcome:ev.approvalOutcome,title:String(entry.info.title || 'Task').slice(0,120),project:String(entry.info.cwd || '').slice(0,256),provider:String(entry.info.agent || '').slice(0,80),taskState:String(entry.info.taskState || ''),preview,previewComplete,availableActions};
            const inserted=db.query('INSERT INTO activity_v2(task,body) VALUES (?,?)').run(task,JSON.stringify(record));
            activity.push({cursor:Number(inserted.lastInsertRowid),...record});
          }
        }
      } db.exec('DELETE FROM activity WHERE id < (SELECT COALESCE(MAX(id),0)-2000 FROM activity)');db.exec('DELETE FROM activity_v2 WHERE cursor < (SELECT COALESCE(MAX(cursor),0)-9999 FROM activity_v2)');})();
      result={ok:true,activity};
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
    } else if(op==='activityV2') {
      result=db.transaction(()=>{
        const latest=(db.query('SELECT COALESCE(MAX(cursor),0) AS cursor FROM activity_v2').get() as any).cursor as number;
        const throughCursor=Math.min(data.throughCursor ?? latest,latest);
        const oldest=(db.query('SELECT MIN(cursor) AS cursor FROM activity_v2').get() as any).cursor as number|null;
        const replayGap=oldest!==null && data.cursor<oldest-1;
        const rows=db.query('SELECT cursor,body FROM activity_v2 WHERE cursor>? AND cursor<=? ORDER BY cursor LIMIT 200').all(data.cursor,throughCursor) as any[];
        const events=rows.map(row=>({cursor:row.cursor,...JSON.parse(row.body)}));
        const nextCursor=events.at(-1)?.cursor ?? data.cursor;
        const hasMore=!!db.query('SELECT cursor FROM activity_v2 WHERE cursor>? AND cursor<=? LIMIT 1').get(nextCursor,throughCursor);
        const sessions=(db.query('SELECT info FROM tasks').all() as any[]).map(row=>JSON.parse(row.info));
        const pendingApprovals=(db.query("SELECT task,request,body FROM approvals WHERE state='pending'").all() as any[]).map(row=>({agentSessionId:row.task,requestId:row.request,event:JSON.parse(row.body)}));
        return {sessions,pendingApprovals,events,nextCursor,throughCursor,hasMore,replayGap};
      })();
    } else if(op==='action:claim') {
      result=db.transaction(()=>{
        const previous=db.query('SELECT args,state,reason FROM activity_actions WHERE device=? AND operation=?').get(data.device,data.operationId) as any;
        if(previous){if(previous.args!==data.args)throw new Error('Operation ID reused with different arguments.');return {operationId:data.operationId,state:previous.state,reason:previous.reason,fresh:false};}
        db.query('INSERT INTO activity_actions VALUES (?,?,?,?,?,?)').run(data.device,data.operationId,data.args,'claimed',null,Date.now());
        return {operationId:data.operationId,state:'claimed',fresh:true};
      })();
    } else if(op==='action:dispatching') {
      db.query("UPDATE activity_actions SET state='dispatching',updated=? WHERE device=? AND operation=? AND state='claimed'").run(Date.now(),data.device,data.operationId);
      result={operationId:data.operationId,state:'dispatching'};
    } else if(op==='action:reject') {
      db.query("UPDATE activity_actions SET state='rejected',reason=?,updated=? WHERE device=? AND operation=? AND state='claimed'").run(data.reason || 'Action no longer available',Date.now(),data.device,data.operationId);
      result={operationId:data.operationId,state:'rejected',reason:data.reason};
    } else if(op==='action:finish') {
      db.query("UPDATE activity_actions SET state=?,reason=?,updated=? WHERE device=? AND operation=? AND state='dispatching'").run(data.state,data.reason || null,Date.now(),data.device,data.operationId);
      result={operationId:data.operationId,state:data.state,reason:data.reason};
    } else if(op==='action:status') {
      const row=db.query('SELECT state,reason FROM activity_actions WHERE device=? AND operation=?').get(data.device,data.operationId) as any;
      result=row?{operationId:data.operationId,state:row.state,reason:row.reason}:null;
    } else if(op==='action:source') {
      const row=db.query('SELECT body FROM activity_v2 WHERE cursor=?').get(data.sourceCursor) as any;
      result=row?JSON.parse(row.body):null;
    } else if(op==='close') {
      db.close(); result=true;
    }
    self.postMessage({id,result});
  } catch(error) { self.postMessage({id,error:error instanceof Error?error.message:'Storage failure'}); }
};
