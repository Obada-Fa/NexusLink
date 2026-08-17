import type { AgentId, AgentInfo, WsMessage } from '@nexuslink/rpc-types';

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

interface AgentDefinition {
  id: AgentId;
  label: string;
  binaries: string[];
  supportsChat: boolean;
  supportsTerminal: boolean;
  installHint: string;
  buildRunArgs: (prompt: string, continueSession?: boolean) => string[];
  buildTerminalArgs: () => string[];
}

const AGENT_DEFINITIONS: AgentDefinition[] = [
  {
    id: 'cursor',
    label: 'Cursor',
    binaries: ['agent', 'cursor-agent'],
    supportsChat: true,
    supportsTerminal: true,
    installHint: 'Install Cursor CLI: curl https://cursor.com/install -fsS | bash',
    buildRunArgs: (prompt) => ['-p', prompt, '--output-format', 'text'],
    buildTerminalArgs: () => [],
  },
  {
    id: 'opencode',
    label: 'OpenCode',
    binaries: ['opencode'],
    supportsChat: true,
    supportsTerminal: true,
    installHint: 'Install OpenCode: curl -fsSL https://opencode.ai/install | bash',
    buildRunArgs: (prompt, continueSession) =>
      continueSession ? ['run', '--continue', prompt] : ['run', prompt],
    buildTerminalArgs: () => [],
  },
  {
    id: 'antigravity',
    label: 'Antigravity',
    binaries: ['agy', 'antigravity'],
    supportsChat: false,
    supportsTerminal: true,
    installHint: 'Install Antigravity CLI: curl -fsSL https://antigravity.google/cli/install.sh | bash',
    buildRunArgs: () => [],
    buildTerminalArgs: () => [],
  },
];

interface AgentRun {
  proc: ReturnType<typeof Bun.spawn>;
  ws: WebSocket;
}

const runs = new Map<string, AgentRun>();
let sendFn: SendFn;

export function setAgentSend(fn: SendFn) {
  sendFn = fn;
}

function definitionFor(id: AgentId): AgentDefinition | undefined {
  return AGENT_DEFINITIONS.find((d) => d.id === id);
}

async function resolveBinary(binaries: string[]): Promise<{ path: string; binary: string } | null> {
  for (const binary of binaries) {
    try {
      const proc = Bun.spawn(['/bin/bash', '-lc', `command -v ${binary}`], {
        stdout: 'pipe',
        stderr: 'pipe',
      });
      const out = (await new Response(proc.stdout).text()).trim();
      const code = await proc.exited;
      if (code === 0 && out) return { path: out, binary };
    } catch {
      /* try next alias */
    }
  }
  return null;
}

async function readVersion(binaryPath: string, agentId: AgentId): Promise<string | undefined> {
  const flags =
    agentId === 'cursor'
      ? ['--version']
      : agentId === 'opencode'
        ? ['--version']
        : ['--help'];

  try {
    const proc = Bun.spawn([binaryPath, ...flags], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const text = `${stdout}\n${stderr}`.trim();
    const firstLine = text.split('\n').find((line) => line.trim())?.trim();
    return firstLine?.slice(0, 120);
  } catch {
    return undefined;
  }
}

export async function listAgents(): Promise<AgentInfo[]> {
  const results: AgentInfo[] = [];

  for (const def of AGENT_DEFINITIONS) {
    const resolved = await resolveBinary(def.binaries);
    const version = resolved ? await readVersion(resolved.path, def.id) : undefined;
    results.push({
      id: def.id,
      label: def.label,
      path: resolved?.path,
      installed: !!resolved,
      version,
      supportsChat: def.supportsChat,
      supportsTerminal: def.supportsTerminal,
      installHint: def.installHint,
    });
  }

  return results;
}

function streamProcessOutput(runId: string, proc: ReturnType<typeof Bun.spawn>, ws: WebSocket) {
  const push = (data: string, done = false, exitCode?: number) => {
    if (!sendFn || !data && !done) return;
    sendFn(ws, { type: 'agent-output', runId, data, done, exitCode });
  };

  const decoder = new TextDecoder();

  (async () => {
    for await (const chunk of proc.stdout) {
      push(decoder.decode(chunk));
    }
  })().catch(() => {});

  (async () => {
    for await (const chunk of proc.stderr) {
      push(decoder.decode(chunk));
    }
  })().catch(() => {});

  void proc.exited.then((code) => {
    runs.delete(runId);
    push('', true, code);
  });
}

export async function runAgent(
  agentId: AgentId,
  prompt: string,
  cwd: string | undefined,
  continueSession: boolean | undefined,
  ws: WebSocket,
): Promise<{ runId: string }> {
  const def = definitionFor(agentId);
  if (!def) throw new Error(`Unknown agent: ${agentId}`);
  if (!def.supportsChat) {
    throw new Error(`${def.label} only supports interactive terminal mode from mobile`);
  }

  const resolved = await resolveBinary(def.binaries);
  if (!resolved) throw new Error(`${def.label} is not installed on the host`);

  const runId = crypto.randomUUID();
  const args = def.buildRunArgs(prompt, continueSession);
  const proc = Bun.spawn([resolved.path, ...args], {
    cwd: cwd || process.env.HOME || process.cwd(),
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    env: { ...process.env, TERM: 'dumb', NO_COLOR: '1' },
  });

  runs.set(runId, { proc, ws });
  streamProcessOutput(runId, proc, ws);
  return { runId };
}

export function cancelAgentRun(runId: string): void {
  const run = runs.get(runId);
  if (!run) return;
  try {
    run.proc.kill('SIGTERM');
  } catch {
    /* ignore */
  }
  runs.delete(runId);
}

export function getAgentTerminalLaunch(agentId: AgentId): { command: string; args: string[] } {
  const def = definitionFor(agentId);
  if (!def) throw new Error(`Unknown agent: ${agentId}`);
  return {
    command: def.binaries[0],
    args: def.buildTerminalArgs(),
  };
}

export async function resolveAgentBinary(agentId: AgentId): Promise<string> {
  const def = definitionFor(agentId);
  if (!def) throw new Error(`Unknown agent: ${agentId}`);
  const resolved = await resolveBinary(def.binaries);
  if (!resolved) throw new Error(`${def.label} is not installed on the host`);
  return resolved.path;
}
