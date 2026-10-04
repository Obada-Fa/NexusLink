import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LibraryStorage } from './storage';
import { ChatService, sessionSummary, identity, folderIdentity } from './index';
import { parseCodexJsonl } from './providers/codex';
import type { ChatSummary } from '../../rpc-types/src/chat';
import type { AgentSessionInfo } from '../../rpc-types/src/index';
const directories: string[]=[];
const stores: LibraryStorage[]=[];
const services: ChatService[]=[];
function directory() {const path=mkdtempSync(join(tmpdir(),'nexuslink-library-'));directories.push(path);return path;}
function storage() {const store=new LibraryStorage(directory());stores.push(store);return store;}
function row(id:string,activityAt:number|null,source='codex'):ChatSummary {
  return {id,hostId:'pc',source,sourceName:source,nativeId:id,title:'Same title',folderId:'folder',folderPath:'/workspace',folderName:'workspace',activityAt,archived:false,execution:'unknown',capabilities:{read:true,continue:false,safety:'unknown'}};
}
afterEach(async()=>{
  for(const service of services.splice(0))await service.close();
  for(const store of stores.splice(0))store.close();
  for(const path of directories.splice(0))rmSync(path,{recursive:true,force:true});
});
describe('chat library index',()=>{
  test('orders mixed providers, keeps identical titles separate, and restarts expired cursors',()=>{
    const store=storage();
    store.upsert([row('a',1),row('b',3,'claude'),row('c',2)]);
    const first=store.page({limit:2});
    expect(first.items.map((item:any)=>item.id)).toEqual(['b','c']);
    expect(store.page({limit:2,cursor:first.nextCursor!}).items.map((item:any)=>item.id)).toEqual(['a']);
    store.upsert([row('d',4)]);
    expect(store.page({cursor:first.nextCursor!}).restart).toBe(true);
    expect(store.page({query:'SAME TITLE'}).items).toHaveLength(4);
    expect(store.page({source:'claude'}).items).toHaveLength(1);
  });
  test('merges a newly learned native identity and retains an alias',()=>{
    const store=storage();
    const initial={...row('local',10),nativeId:undefined,agentSessionId:'session',managed:true};
    store.upsert([initial]);
    store.upsert([{...row('native',10),agentSessionId:'session',managed:true}]);
    expect(store.page({}).items).toHaveLength(1);
    expect(store.get('local')?.id).toBe('native');
    store.upsert([row('native',8)]);
    expect(store.get('native')?.agentSessionId).toBe('session');
    expect(store.get('native')?.managed).toBe(true);
  });
  test('attaching an imported chat preserves provider activity time',()=>{
    const store=storage();store.upsert([row('native',100)]);
    store.upsert([{...row('native',999),managed:false,agentSessionId:'attached'}]);
    expect(store.get('native')?.activityAt).toBe(100);
  });
  test('groups folders, searches recorded paths, and separates archives',()=>{
    const store=storage();store.upsert([row('a',1),row('b',3),{...row('c',2),folderId:null,folderPath:null,folderName:'No folder'}, {...row('archived',4),archived:true}]);
    const folders=store.page({},true).items as any[];
    expect(folders[0].count).toBe(2);expect(folders[0].latestTitle).toBe('Same title');
    expect(store.page({query:'WORKSPACE'}).items).toHaveLength(2);
    expect(store.page({folderId:null}).items).toHaveLength(1);
    expect(store.page({archived:true}).items).toHaveLength(1);
  });
  test('retains indexed rows on failures and removes missing source rows after successful scans',()=>{
    const store=storage();store.upsert([row('a',1),row('b',2)]);
    store.setHealth({source:'codex',state:'error',reason:'Timed out'});
    expect(store.page({}).items).toHaveLength(2);
    store.upsert([row('a',1)],'codex',true);
    expect(store.page({}).items).toHaveLength(1);
  });
  test('pages stable history identities within 512 KiB and labels oversized text',()=>{
    const store=storage();
    const raw=Array.from({length:250},(_,i)=>({kind:i%2?'text':'user',ts:i,text:i===249?'x'.repeat(800000):'message '+i}));
    store.indexHistory('chat','one',raw);
    const first=store.historyPage('chat',{});
    expect(first.events).toHaveLength(100);
    expect(first.events[0].seq).toBe(151);
    expect(first.events.at(-1)?.truncated).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(first))).toBeLessThan(512*1024);
    const second=store.historyPage('chat',{olderCursor:first.olderCursor!});
    expect(second.events[0].seq).toBe(51);
    const ids=first.events.map(event=>event.id);
    store.indexHistory('chat','two',raw);
    expect(store.historyPage('chat',{}).events.map(event=>event.id)).toEqual(ids);
    store.indexHistory('chat','three',[...raw,{kind:'text',ts:300,text:'new'}]);
    expect(store.historyPage('chat',{olderCursor:first.olderCursor!}).restart).toBe(true);
  });
  test('durable operations never claim twice and recover uncertain dispatch after restart',()=>{
    const path=directory();let store=new LibraryStorage(path);
    expect(store.claim('phone','op','args').fresh).toBe(true);
    store.finish('phone',{operationId:'op',state:'dispatching'});store.close();
    store=new LibraryStorage(path);stores.push(store);
    expect(store.operation('phone','op')?.state).toBe('uncertain');
    expect(store.claim('phone','op','args').fresh).toBe(false);
    expect(()=>store.claim('phone','op','changed')).toThrow('different arguments');
    expect(store.operation('another-phone','op')).toBeNull();
  });
  test('10,000 indexed conversations query under the 250 ms target',()=>{
    const store=storage();store.upsert(Array.from({length:10000},(_,i)=>row('chat-'+i,i)));
    const elapsed:number[]=[];
    for(let i=0;i<25;i++){const start=performance.now();expect(store.page({limit:50}).items).toHaveLength(50);elapsed.push(performance.now()-start);}
    elapsed.sort((a,b)=>a-b);console.info(`[chat-library performance] 10,000 rows, 25 queries: p95=${elapsed[23].toFixed(2)}ms`);expect(elapsed[23]).toBeLessThan(250);
  });
});
describe('folder and source identities',()=>{
  test('normalizes drive and UNC paths, preserves Linux case, keeps missing folders separate',()=>{
    expect(folderIdentity('D:/Projects/Chat/','win32').id).toBe(folderIdentity('d:\\projects\\chat','win32').id);
    expect(folderIdentity('\\\\server\\share\\Work','win32').id).toBe(folderIdentity('//SERVER/share/work/','win32').id);
    expect(folderIdentity('/work/Chat','linux').id).not.toBe(folderIdentity('/work/chat','linux').id);
    expect(folderIdentity('relative','linux').id).toBeNull();
    expect(folderIdentity(undefined).name).toBe('No folder');
    expect(identity('pc','codex','one')).not.toBe(identity('pc','claude','one'));
  });
  test('does not mark imported sessions completed or safe to continue',()=>{
    const session:AgentSessionInfo={agentSessionId:'a',agent:'codex',cwd:'',title:'test',createdAt:10,busy:false,status:'running',imported:true,hostChatId:'native'};
    const summary=sessionSummary('pc',session);
    expect(summary.execution).toBe('unknown');expect(summary.capabilities.safety).toBe('unknown');expect(summary.activityAt).toBeNull();
    expect(sessionSummary('pc',{...session,imported:false,taskState:'interrupted'}).capabilities.continue).toBe(false);
  });
  test('parses recognized Codex user/assistant records and partial final lines',()=>{
    const text=[{type:'session_meta',payload:{id:'a'}},{type:'response_item',timestamp:'2026-01-01T00:00:00Z',payload:{type:'message',role:'user',content:[{type:'input_text',text:'Hello'}]}},{type:'response_item',payload:{type:'message',role:'assistant',content:[{type:'output_text',text:'Hi'}]}}].map(row=>JSON.stringify(row)).join('\n')+'\n{"incomplete';
    expect(parseCodexJsonl(text).map(event=>event.text)).toEqual(['Hello','Hi']);
    expect(parseCodexJsonl(text)[1].ts).toBe(0);
  });
});
test('concurrent duplicate sends dispatch once and refuse busy/imported chats',async()=>{
  const path=directory();let count=0;
  const session:AgentSessionInfo={agentSessionId:'owned',agent:'mock',cwd:path,title:'Task',createdAt:1,updatedAt:1,busy:false,status:'running'};
  const service=await new ChatService({directory:path,hostId:'pc',notify:()=>{},backgroundDiscovery:false,gateway:{sessions:()=>[session],history:async()=>({events:[],hasMore:false}),send:()=>{count++;return {ok:true};},flush:async()=>{},bin:()=>null}}).initialize();services.push(service);
  const chatId=sessionSummary('pc',session).id;
  const params={chatId,text:'hello',operationId:'op'};
  const results=await Promise.all([service.send('phone',params),service.send('phone',params)]);
  expect(count).toBe(1);expect(results.map(result=>result.state)).toEqual(['delivered','delivered']);
  session.busy=true;
  expect((await service.send('phone',{...params,operationId:'busy'})).state).toBe('rejected');
  session.busy=false;session.imported=true;
  expect((await service.send('phone',{...params,operationId:'imported'})).state).toBe('rejected');expect(count).toBe(1);
});
