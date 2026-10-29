// Approvals for agents NexusLink did not start (Claude Desktop, the claude CLI), received
// through the agent's own official PermissionRequest hook. The hook never decides by itself:
// with no answer from the phone the agent shows its normal prompt.

export type ExternalApprovalKind = 'approval' | 'question' | 'plan';

export interface ExternalApprovalQuestion {
  question: string;
  header?: string;
  options: { label: string; description?: string }[];
  multiSelect?: boolean;
}

export interface ExternalApproval {
  id: string;
  agent: 'claude';
  /** Library id of the chat (same id the chat library uses). */
  chatId: string;
  /** The agent's own session id. */
  sessionId: string;
  kind: ExternalApprovalKind;
  /** One line: "Run: npm test", "Edit login.dart", the question, "Approve the plan". */
  title: string;
  /** Command, file + change, URL, plan text or tool input (≤ 4000 chars). */
  detail?: string;
  tool: string;
  cwd?: string;
  /** Set when a sub-agent asked ("Explore", "general-purpose"…). */
  subagent?: string;
  questions?: ExternalApprovalQuestion[];
  /** True when the PC shows the same prompt (Claude Desktop): either side may answer first. */
  mirrored: boolean;
  createdAt: number;
  expiresAt: number;
}

export interface ApprovalBridgeStatus {
  /** NexusLink's hook is in ~/.claude/settings.json. */
  claude: { installed: boolean; error?: string };
  /** Hold terminal (claude CLI) prompts for the phone. Desktop prompts are always mirrored. */
  holdTerminal: boolean;
  /** The loopback hook listener is up. */
  listening: boolean;
}

export interface ApprovalRpc {
  'approvals.list': { params: Record<string, never>; result: { items: ExternalApproval[] } };
  'approvals.resolve': {
    params: { id: string; decision: 'allow' | 'deny'; answers?: Record<string, string>; message?: string };
    result: { ok: boolean; message?: string };
  };
  'approvals.status': { params: Record<string, never>; result: ApprovalBridgeStatus };
  'approvals.configure': { params: { claude?: boolean; holdTerminal?: boolean }; result: ApprovalBridgeStatus };
}
