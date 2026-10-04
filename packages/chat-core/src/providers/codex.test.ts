import { test, expect } from 'bun:test';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { CodexAppServer } from './codex';

test('app-server initializes, discovers every page and archive, reads typed history, and resumes native identity', async () => {
  const directory=mkdtempSync(join(tmpdir(),'nexuslink-codex-protocol-'));
  const path=join(directory,'server.js');
  writeFileSync(path, `
    const {createInterface}=require('node:readline');
    let initialized=false;
    const output=value=>process.stdout.write(JSON.stringify(value)+'\\n');
    createInterface({input:process.stdin}).on('line',line=>{
      const message=JSON.parse(line),p=message.params;
      if(message.method==='initialized'){initialized=true;return;}
      if(!message.method)return;
      let result;
      if(message.method==='initialize')result={userAgent:'fixture'};
      else if(!initialized)throw new Error('missing initialized');
      else if(message.method==='thread/list'){
        if(p.sortKey!=='updated_at'||p.limit!==100||!p.sourceKinds.includes('vscode'))throw new Error('invalid discovery');
        result={data:[{id:p.archived?'archived':p.cursor?'older':'latest',cwd:process.cwd(),updatedAt:2,preview:'Saved chat',status:{type:'notLoaded'}}],nextCursor:!p.archived&&!p.cursor?'page-two':null};
      }else if(message.method==='thread/read')result={thread:{turns:[{startedAt:1,items:[{id:'user',type:'userMessage',content:[{type:'text',text:'Question'}]},{id:'answer',type:'agentMessage',text:'Answer'}]}]}};
      else if(message.method==='thread/resume')result={thread:{id:p.threadId}};
      else if(message.method==='turn/start'){
        if(p.threadId!=='latest')throw new Error('changed native identity');
        result={turn:{id:'turn-one'}};
      }else throw new Error('unexpected method');
      output({id:message.id,result});
      if(message.method==='turn/start'){
        output({method:'item/agentMessage/delta',params:{threadId:p.threadId,itemId:'answer',delta:'Continued'}});
        output({id:'approval',method:'item/commandExecution/requestApproval',params:{threadId:p.threadId,reason:'Run command'}});
      }
    });
  `);
  const notifications:string[]=[];
  let approve!:()=>void;
  const approved=new Promise<void>(resolve=>{approve=resolve;});
  const server=new CodexAppServer({notification:(method)=>notifications.push(method),request:(id,method)=>{expect(method).toBe('item/commandExecution/requestApproval');server.respond(id,{decision:'decline'});approve();}});
  try {
    await server.initialize(process.execPath,undefined,[path]);
    const rows=await server.list();
    expect(rows.map(row=>row.hostChatId)).toEqual(['latest','older','archived']);
    expect(rows.every(row=>row.resumable===false)).toBe(true);
    expect(rows.every(row=>row.busy===false)).toBe(true);
    expect((await server.history('latest')).map(event=>event.text)).toEqual(['Question','Answer']);
    const resumed=await server.request('thread/resume',{threadId:'latest'});
    expect(resumed.thread.id).toBe('latest');
    await server.request('turn/start',{threadId:resumed.thread.id,input:[{type:'text',text:'Reply'}]});
    await approved;
    expect(notifications).toContain('item/agentMessage/delta');
  } finally { server.close();rmSync(directory,{recursive:true,force:true}); }
});
