import { listClaudeHostChats, listCursorCliHostChats, listCursorIdeHostChats, listAgyHostChats, loadHostChatHistory, setDiscoveryLimit, takeReadIssue } from './local';
import { CodexAppServer, listCodexLocal, loadCodexLocal } from './codex';

setDiscoveryLimit(Number.MAX_SAFE_INTEGER);
async function opencodeList(bin: string) {
  // Omitting -n requests all sessions in supported OpenCode versions.
  const child = Bun.spawn([bin,'session','list','--format','json'],{stdout:'pipe',stderr:'pipe'});
  self.postMessage({pid:child.pid});
  const timer=setTimeout(()=>child.kill(),12000);
  try {
    const [output, errors, exit] = await Promise.all([new Response(child.stdout).text(),new Response(child.stderr).text(),child.exited]);
    if (exit) throw new Error('OpenCode is unavailable. Check installation and sign-in on the PC.');
    const rows=JSON.parse(output);
    if (!Array.isArray(rows)) throw new Error('Unsupported OpenCode session format');
    return rows.map(row=>({agent:'opencode',hostChatId:row.id,title:row.title || 'OpenCode conversation',cwd:row.directory || row.cwd || '',updatedAt:typeof row.time?.updated === 'number' ? row.time.updated : typeof row.updated === 'number' ? row.updated : 0,resumable:true,source:'OpenCode'}));
  } finally { clearTimeout(timer); }
}
async function opencodeHistory(bin: string, id: string) {
  const child=Bun.spawn([bin,'export',id],{stdout:'pipe',stderr:'pipe'});
  self.postMessage({pid:child.pid});
  const timer=setTimeout(()=>child.kill(),12000);
  try {
    const [output,,exit]=await Promise.all([new Response(child.stdout).text(),new Response(child.stderr).text(),child.exited]);
    if(exit) throw new Error('OpenCode could not export this conversation');
    const { parseOpencodeExport } = await import('./local');
    return parseOpencodeExport(JSON.parse(output));
  } finally { clearTimeout(timer); }
}
self.onmessage = async (event: MessageEvent) => {
  const {source,op,nativeId,bin} = event.data;
  let codex: CodexAppServer | undefined;
  try {
    let result: any;
    let reason: string | undefined;
    if (source === 'codex') {
      try {
        codex = new CodexAppServer({spawned:pid=>self.postMessage({pid})}); await codex.initialize(bin || 'codex');
        result = op === 'scan' ? await codex.list() : await codex.history(nativeId);
      } catch {
        result = op === 'scan' ? listCodexLocal() : loadCodexLocal(nativeId);
        reason = 'Codex app-server unavailable; showing saved local history. Update Codex or check sign-in on the PC.';
      }
    } else if (op === 'scan') {
      if (source === 'claude') result=listClaudeHostChats();
      else if (source === 'cursor') result=[...listCursorCliHostChats(!!bin),...listCursorIdeHostChats()];
      else if (source === 'antigravity') result=listAgyHostChats();
      else if (source === 'opencode') { if(!bin)throw new Error('OpenCode is not installed');result=await opencodeList(bin); }
      else throw new Error('Unknown conversation source');
    } else {
      result=source === 'opencode' && bin ? await opencodeHistory(bin,nativeId) : loadHostChatHistory(source,nativeId,bin);
      if (!result.length) reason='This app’s history format could not be read, or no messages are available yet.';
    }
    if(takeReadIssue())reason='Some saved files could not be read completely. Showing available chats; check this app on the PC and retry.';
    self.postMessage({result,reason});
  } catch { self.postMessage({error:`Couldn’t ${op === 'scan' ? 'refresh' : 'read'} ${source}. Check the app and its files on the PC, then retry.`}); }
  finally { codex?.close(); }
};
