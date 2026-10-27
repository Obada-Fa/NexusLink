import { ChatService } from '../../../../../packages/chat-core/src/index';
import { listAgentSessions, promptAgent, resolveBin, openHostChat, cancelAgent, agentSessionLive, flushAgentDeltas } from '../handlers/agents';
import { storedHistory, flushAgents } from './agent-store';

export async function createChatLibrary(directory: string, hostId: string, notify: (connection: object, revision: number) => void) {
  return new ChatService({directory,hostId,notify,gateway:{
    sessions:listAgentSessions,
    history:(id,params)=>{flushAgentDeltas(id);return storedHistory(id,params);},
    send:promptAgent,
    flush:flushAgents,
    bin:source=>resolveBin(source === 'cursor' ? 'cursor-agent' : source === 'antigravity' ? 'agy' : source),
    openHostChat: params => openHostChat(params),
    cancel: id => cancelAgent(id),
    live: id => agentSessionLive(id),
  }}).initialize();
}
