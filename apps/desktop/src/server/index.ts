import type { WsMessage, RpcRequest, RpcResponse, RpcMethod } from '@nexuslink/rpc-types';
import { handleFsList } from './handlers/fs';
import { listProcesses } from './handlers/process';
import { getSystemInfo, getPerfSnapshot } from './handlers/system';
import { handleTerminalCreate, handleTerminalInput, handleTerminalResize, handleTerminalKill, setSend as setTerminalSend } from './handlers/terminal';
import { validateToken, generateToken, handleSessionPair, validateSessionTOTP, isLocalDev, generateDevToken } from './handlers/auth';
import { setSend as setSignalingSend } from './handlers/signaling';
import { startSidecarReader } from './sidecar-reader';

type Params = Record<string, unknown>;

export async function startRpcServer(port = 45678) {
  const sessions = new Map<string, { ws: WebSocket; token?: string; pairingData?: { pairingId: string }; isLocal?: boolean }>();

  function send(ws: WebSocket, msg: WsMessage) {
    if (ws.readyState === 1) ws.send(JSON.stringify(msg));
  }

  function findSession(ws: WebSocket): string | undefined {
    let found: string | undefined;
    sessions.forEach((s, id) => {
      if (s.ws === ws) found = id;
    });
    return found;
  }

  function getAuthenticatedSessions(): WebSocket[] {
    const list: WebSocket[] = [];
    sessions.forEach((s) => {
      if (s.token && validateToken(s.token) && s.ws.readyState === 1) {
        list.push(s.ws);
      }
    });
    return list;
  }

  setTerminalSend(send);
  setSignalingSend(send);

  async function dispatch(method: RpcMethod, params: Params, req: RpcRequest<RpcMethod>, ws: WebSocket) {
    let result: unknown;
    switch (method) {
      case 'fs.list':
        result = await handleFsList(params.path as string, params.showHidden as boolean | undefined);
        break;
      case 'process.list':
        result = await listProcesses();
        break;
      case 'process.kill':
        result = undefined;
        break;
      case 'terminal.create':
        result = await handleTerminalCreate(params.cols as number, params.rows as number, params.shell as string | undefined, ws);
        break;
      case 'terminal.input':
        result = await handleTerminalInput(params.terminalId as string, params.data as string);
        break;
      case 'terminal.resize':
        result = await handleTerminalResize(params.terminalId as string, params.cols as number, params.rows as number);
        break;
      case 'terminal.kill':
        result = await handleTerminalKill(params.terminalId as string);
        break;
      case 'system.getInfo':
        result = await getSystemInfo();
        break;
      case 'system.getPerf':
        result = await getPerfSnapshot();
        break;
      case 'session.pair': {
        const pairResult = await handleSessionPair(params.publicKey as string);
        const pairingId = pairResult.totpIssuerUri.split('secret=')[1]?.split('&')[0] ?? '';
        const sessionId = findSession(ws);
        if (sessionId) {
          const s = sessions.get(sessionId);
          if (s) s.pairingData = { pairingId };
        }
        result = pairResult;
        break;
      }
      case 'session.authenticate': {
        const code = params.code as string;
        const sessionId = findSession(ws);
        const isLocal = sessionId ? sessions.get(sessionId)?.isLocal : false;
        let token: string | undefined;

        // Dev bypass: auto-generate token for local connections
        if (isLocal && code.startsWith('dev-')) {
          const dev = generateDevToken();
          token = dev.token;
        } else if (isLocal) {
          // local connection, auto-issue token without TOTP
          const dev = generateDevToken();
          token = dev.token;
        } else {
          // TOTP pairing flow
          const pairingData = sessionId ? sessions.get(sessionId)?.pairingData : undefined;
          if (!pairingData?.pairingId) {
            const response: RpcResponse = { id: req.id, error: 'no active pairing session' };
            send(ws, { type: 'rpc-response', response });
            return;
          }
          const totpValid = await validateSessionTOTP(pairingData.pairingId, code);
          if (!totpValid) {
            const response: RpcResponse = { id: req.id, error: 'invalid totp code' };
            send(ws, { type: 'rpc-response', response });
            return;
          }
          const newToken = generateToken();
          token = newToken.token;
        }

        if (sessionId) {
          const s = sessions.get(sessionId);
          if (s) s.token = token;
        }
        result = { token };
        break;
      }
      case 'session.heartbeat':
        result = undefined;
        break;
      case 'session.disconnect': {
        const sessionId = findSession(ws);
        if (sessionId) sessions.delete(sessionId);
        result = undefined;
        break;
      }
      default:
        result = undefined;
        break;
    }
    const response: RpcResponse = { id: req.id, result };
    send(ws, { type: 'rpc-response', response });
  }

  const server = Bun.serve({
    port,
    fetch(req, srv) {
      const url = new URL(req.url);
      if (url.pathname === '/signal') {
        const isLocal = isLocalDev(req.url);
        // @ts-expect-error Bun upgrade supports data option in runtime
        if (srv.upgrade(req, { data: { isLocal } })) return;
        return new Response('Upgrade failed', { status: 400 });
      }
      return new Response('NexusLink RPC', { status: 200 });
    },
    websocket: {
      open(ws) {
        const id = crypto.randomUUID();
        const isLocal = !!(ws as unknown as { data?: { isLocal?: boolean } }).data?.isLocal;
        sessions.set(id, { ws, isLocal });
      },
      async message(ws, raw) {
        let msg: WsMessage;
        try {
          msg = JSON.parse(raw as unknown as string) as WsMessage;
        } catch {
          return;
        }
        if (msg.type === 'rpc-request') {
          await dispatch(msg.request.method, (msg.request.params as Params) ?? {}, msg.request, ws);
        }
      },
      close(ws) {
        sessions.forEach((s, id) => {
          if (s.ws === ws) sessions.delete(id);
        });
      },
    },
  });

  startSidecarReader(send, getPerfSnapshot, getAuthenticatedSessions);

  return { port };
}
