// Run in a fresh process by agents-subagents.test.ts: store a claude session
// whose background sub-agent was still running, "restart" the host (reload the
// store into a new agents module) and print what a reconnecting phone gets.
import { closeAgentStore, flushAgents, initializeAgentStore, persistAgent, storedHistory } from '../../../workspace/agent-store';
import { agentHistory, listAgentSessions } from '../../agents';

const directory = process.env.NEXUSLINK_DATA_DIR!;
const id = 'replay-subagents';
const info = {
  agentSessionId: id, agent: 'claude', cwd: '/tmp', title: 'Replay', createdAt: 1, updatedAt: 1,
  busy: process.env.REPLAY_BUSY === '1', status: 'running', taskState: process.env.REPLAY_TASKSTATE ?? 'completed', runningAgents: Number(process.env.REPLAY_RUNNING_AGENTS ?? 1), turnId: 't1',
};
const events = JSON.parse(process.env.REPLAY_EVENTS!) as unknown[];

await initializeAgentStore({ directory, hostId: 'test-host' });
await persistAgent({ info, events });
await closeAgentStore();

// Host restart: the store loads rows, the agents module restores sessions.
await initializeAgentStore({ directory, hostId: 'test-host' });
const sessions = listAgentSessions().filter((s) => s.agentSessionId === id);
await Bun.sleep(50);
await flushAgents();
const stored = await storedHistory(id, { afterSeq: 0, limit: 200 });
const memory = agentHistory(id);
await closeAgentStore();
console.log(JSON.stringify({ sessions, stored: stored.events, memory }));
process.exit(0);
