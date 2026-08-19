import type { WsMessage, RpcRequest, RpcResponse, RpcMethod, AgentImageAttachment } from '@nexuslink/rpc-types';
import { gitWorkingTree, handleFsList, handleFsRead, listProjects } from './handlers/fs';
import { killProcess, listProcesses } from './handlers/process';
import { getSystemInfo, getPerfSnapshot } from './handlers/system';
import {
  handleTerminalCreate, handleTerminalInput, handleTerminalResize, handleTerminalKill,
  setSend as setTerminalSend, killTerminalsForSocket,
} from './handlers/terminal';
import { validateToken, generateToken, handleSessionPair, validateSessionTOTP, isLocalDev, isTrustedLan, generateDevToken } from './handlers/auth';
import { getClipboard, setClipboard } from './handlers/clipboard';
import { getScreenMetadata, startCapture, stopCapture, stopCapturesForSocket } from './handlers/screen';
import * as winInput from './native/input';
import { listWindows, activateWindow, adoptWindow, releaseWindow, listApps, refreshApps, launchApp } from './native/wm';
import { createAppSession, listAppSessions, resizeAppSession, closeAppSession, getAppSession } from './native/sessions';
import { startTray, stopTray } from './tray';
import { ensureFirewallRule } from './firewall';
import {
  listAgents, createAgentSession, renameAgentSession, setAgentSessionCwd, listAgentSessions, listHostChats, openHostChat, promptAgent,
  cancelAgent, closeAgentSession, agentHistory, resolveAgentPermission, setAgentBroadcast,
  listAgentModels, AGENT_ICON_NAMES, resolveAgentIcon,
} from '../../../desktop/src/server/handlers/agents';
import { serveStatic, staticAvailable } from './static-server';
import { printLaunchBanner, tailscaleIpv4FromCli } from './launch-banner';
import { startMdns } from './mdns';
import { handleFileDownload, handleFileUpload } from './files-http';
import { startPerfBroadcast } from './perf';

type Params = Record<string, unknown>;

type Session = {
  ws: WebSocket;
  token?: string;
  pairingData?: { pairingId: string };
  isLocal?: boolean;
  address?: string;
  authenticated: boolean;
};

const AUTH_METHODS = new Set<string>([
  'session.pair',
  'session.authenticate',
  'session.heartbeat',
  'session.disconnect',
]);

export async function startRpcServer(port = 45678, hostname?: string) {
  const sessions = new Map<string, Session>();

  let bindHost = hostname ?? process.env.NEXUSLINK_HOST ?? process.env.HOST;
  const tailscaleOnly = process.env.NEXUSLINK_TAILSCALE_ONLY === '1' || process.env.TAILSCALE_ONLY === '1';

  if (!bindHost && tailscaleOnly) {
    const tsIps = tailscaleIpv4FromCli();
    if (tsIps.length > 0) {
      bindHost = tsIps[0];
      console.log(`[windows-host] Tailscale-only mode: binding to ${bindHost}`);
    } else {
      console.warn('[windows-host] Tailscale-only requested but no Tailscale IPv4 found; defaulting to 0.0.0.0');
    }
  }

  bindHost = bindHost ?? '0.0.0.0';

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
  const broadcastAll = (msg: WsMessage) => {
    for (const ws of getAuthenticatedSessions()) send(ws, msg);
  };
  setAgentBroadcast(broadcastAll);
  void Promise.all(Object.keys(AGENT_ICON_NAMES).map((id) => resolveAgentIcon(id))).catch(() => {});

  async function dispatch(method: RpcMethod, params: Params, req: RpcRequest<RpcMethod>, ws: WebSocket) {
    const sessionId = findSession(ws);
    const session = sessionId ? sessions.get(sessionId) : undefined;

    if (!AUTH_METHODS.has(method) && !session?.authenticated) {
      const response: RpcResponse = { id: req.id, error: 'not authenticated' };
      send(ws, { type: 'rpc-response', response });
      return;
    }

    let result: unknown;
    switch (method) {
      case 'fs.list':
        result = await handleFsList(params.path as string, params.showHidden as boolean | undefined);
        break;
      case 'fs.read':
        result = await handleFsRead(params.path as string);
        break;
      case 'fs.listProjects':
        result = await listProjects();
        break;
      case 'fs.gitStatus':
        result = await gitWorkingTree(params.cwd as string);
        break;
      case 'process.list':
        result = await listProcesses();
        break;
      case 'process.kill':
        killProcess(params.pid as number);
        result = undefined;
        break;
      case 'terminal.create':
        result = handleTerminalCreate(params.cols as number, params.rows as number, params.shell as string | undefined, ws);
        break;
      case 'terminal.input':
        result = handleTerminalInput(params.terminalId as string, params.data as string);
        break;
      case 'terminal.resize':
        result = handleTerminalResize(params.terminalId as string, params.cols as number, params.rows as number);
        break;
      case 'terminal.kill':
        result = handleTerminalKill(params.terminalId as string);
        break;
      case 'system.getInfo':
        result = await getSystemInfo();
        break;
      case 'system.getPerf':
        result = await getPerfSnapshot();
        break;
      case 'input.mouseMove':
        result = winInput.mouseMove(params.dx as number, params.dy as number);
        break;
      case 'input.mouseClick':
        result = winInput.mouseClick(params.button as string, params.x as number | undefined, params.y as number | undefined);
        break;
      case 'input.buttonDown':
        result = winInput.buttonDown(params.button as string, params.x as number | undefined, params.y as number | undefined);
        break;
      case 'input.buttonUp':
        result = winInput.buttonUp(params.button as string, params.x as number | undefined, params.y as number | undefined);
        break;
      case 'input.mouseMoveAbs':
        result = winInput.mouseMoveAbs(params.x as number, params.y as number);
        break;
      case 'input.mouseScroll':
        result = winInput.mouseScroll(
          params.deltaX as number,
          params.deltaY as number,
          params.x as number,
          params.y as number,
        );
        break;
      case 'input.keyEvent':
        result = winInput.keyEvent(params.key as string, params.modifiers as string[] | undefined);
        break;
      case 'input.typeText':
        result = winInput.typeText((params.text as string) ?? '');
        break;
      case 'window.list':
        result = listWindows();
        break;
      case 'window.adopt':
        result = adoptWindow(
          params.windowId as string,
          params.viewportW as number | undefined,
          params.viewportH as number | undefined,
        );
        break;
      case 'window.release':
        result = releaseWindow(params.windowId as string);
        break;
      case 'window.activate':
        result = activateWindow(params.windowId as string);
        break;
      case 'apps.list':
        result = await listApps();
        break;
      case 'apps.refresh':
        result = await refreshApps();
        break;
      case 'apps.launch':
        result = launchApp(params.appId as string);
        break;
      case 'appSession.create':
        result = await createAppSession(
          params.appId as string,
          params.width as number,
          params.height as number,
          params.dpr as number | undefined,
        );
        break;
      case 'appSession.list':
        result = listAppSessions();
        break;
      case 'appSession.resize':
        result = resizeAppSession(params.sessionId as string, params.width as number, params.height as number);
        break;
      case 'appSession.close':
        closeAppSession(params.sessionId as string);
        result = undefined;
        break;
      case 'webrtc.start':
        result = { available: false, reason: 'WebRTC is not wired on the Windows host yet; MJPEG capture is used instead.' };
        break;
      case 'webrtc.signal':
      case 'webrtc.stop':
        result = undefined;
        break;
      case 'clipboard.get':
        result = getClipboard();
        break;
      case 'clipboard.set':
        result = setClipboard((params.text as string) ?? '');
        break;
      case 'agent.list':
        result = listAgents();
        break;
      case 'agent.createSession':
        result = createAgentSession(
          params.agent as string,
          params.cwd as string | undefined,
          params.title as string | undefined,
        );
        break;
      case 'agent.renameSession':
        result = renameAgentSession(
          params.agentSessionId as string,
          (params.title as string) ?? '',
        );
        break;
      case 'agent.setSessionCwd':
        result = setAgentSessionCwd(
          params.agentSessionId as string,
          (params.cwd as string) ?? '',
        );
        break;
      case 'agent.listSessions':
        result = listAgentSessions();
        break;
      case 'agent.listHostChats':
        result = listHostChats(typeof params.agent === 'string' ? params.agent : undefined);
        break;
      case 'agent.openHostChat':
        result = openHostChat({
          agent: params.agent as string,
          hostChatId: params.hostChatId as string,
          cwd: typeof params.cwd === 'string' && params.cwd.trim() ? params.cwd : undefined,
          title: typeof params.title === 'string' ? params.title : undefined,
        });
        break;
      case 'agent.listModels':
        result = listAgentModels(params.agent as string);
        break;
      case 'agent.prompt':
        result = promptAgent(
          params.agentSessionId as string,
          (params.text as string) ?? '',
          {
            model: typeof params.model === 'string' ? params.model : undefined,
            mode: params.mode === 'plan' || params.mode === 'ask' || params.mode === 'agent'
              ? params.mode
              : undefined,
            thinking: typeof params.thinking === 'string' ? params.thinking : undefined,
            images: Array.isArray(params.images)
              ? params.images as AgentImageAttachment[]
              : undefined,
          },
        );
        break;
      case 'agent.permission':
        result = resolveAgentPermission(
          params.agentSessionId as string,
          params.requestId as string,
          params.allow as boolean,
        );
        break;
      case 'agent.cancel':
        result = cancelAgent(params.agentSessionId as string);
        break;
      case 'agent.close':
        result = closeAgentSession(params.agentSessionId as string);
        break;
      case 'agent.history':
        result = agentHistory(params.agentSessionId as string);
        break;
      case 'ide.start':
        result = { available: false, running: false, reason: 'code-server is not wired on the Windows host yet' };
        break;
      case 'ide.stop':
        result = { ok: false };
        break;
      case 'ide.status':
        result = { available: false, running: false, reason: 'code-server is not wired on the Windows host yet' };
        break;
      case 'screen.startCapture': {
        const sessionId = typeof params.sessionId === 'string' ? params.sessionId : undefined;
        const hwnd = sessionId ? getAppSession(sessionId)?.hwnd : undefined;
        result = startCapture(
          (params.quality as 'low' | 'medium' | 'high' | 'full') || 'medium',
          (params.fps as number) || 12,
          ws,
          undefined,
          (params.windowId as string | undefined) || hwnd,
        );
        break;
      }
      case 'screen.stopCapture':
        stopCapture(params.streamId as string);
        result = undefined;
        break;
      case 'screen.getMetadata':
        result = getScreenMetadata();
        break;
      case 'session.pair': {
        const pairResult = await handleSessionPair(params.publicKey as string);
        const pairingId = pairResult.totpIssuerUri.split('secret=')[1]?.split('&')[0] ?? '';
        if (sessionId) {
          const s = sessions.get(sessionId);
          if (s) s.pairingData = { pairingId };
        }
        result = pairResult;
        break;
      }
      case 'session.authenticate': {
        const code = params.code as string;
        const isLocal = sessionId ? sessions.get(sessionId)?.isLocal : false;
        let token: string | undefined;

        if (isLocal && process.env.NEXUSLINK_DEV === '1') {
          token = generateDevToken().token;
        } else {
          const pairingData = sessionId ? sessions.get(sessionId)?.pairingData : undefined;
          if (!pairingData?.pairingId) {
            const response: RpcResponse = { id: req.id, error: 'no active pairing session' };
            send(ws, { type: 'rpc-response', response });
            return;
          }
          const totpValid = await validateSessionTOTP(pairingData.pairingId, code);
          if (!totpValid) {
            const addr = sessionId ? sessions.get(sessionId)?.address : undefined;
            if (isTrustedLan(addr)) {
              console.warn(`[auth] TOTP mismatch from ${addr}; accepting LAN pairing`);
            } else {
              const response: RpcResponse = { id: req.id, error: 'invalid totp code' };
              send(ws, { type: 'rpc-response', response });
              return;
            }
          }
          token = generateToken().token;
          console.log('[auth] session authenticated');
        }

        if (sessionId) {
          const s = sessions.get(sessionId);
          if (s) { s.token = token; s.authenticated = true; }
        }
        result = { token };
        break;
      }
      case 'session.heartbeat':
        result = undefined;
        break;
      case 'session.disconnect': {
        if (sessionId) sessions.delete(sessionId);
        result = undefined;
        break;
      }
      default:
        throw new Error(`unknown method: ${method}`);
    }
    const response: RpcResponse = { id: req.id, result };
    send(ws, { type: 'rpc-response', response });
  }

  const server = Bun.serve({
    hostname: bindHost,
    port,
    async fetch(req, srv) {
      const url = new URL(req.url);
      if (url.pathname === '/files') {
        if (req.method === 'GET') return handleFileDownload(url);
        if (req.method === 'POST' || req.method === 'PUT') return handleFileUpload(url, req);
        return new Response('Method not allowed', { status: 405 });
      }
      if (url.pathname === '/signal' || url.pathname === '/rpc') {
        const isLocal = isLocalDev(req.url);
        const address = srv.requestIP(req)?.address;
        // @ts-expect-error Bun upgrade supports data option in runtime
        if (srv.upgrade(req, { data: { isLocal, address } })) return;
        return new Response('Upgrade failed', { status: 400 });
      }
      const staticResp = await serveStatic(url.pathname);
      if (staticResp) return staticResp;
      return new Response('NexusLink Windows host', { status: 200 });
    },
    websocket: {
      open(ws) {
        const id = crypto.randomUUID();
        const data = (ws as unknown as { data?: { isLocal?: boolean; address?: string } }).data;
        const isLocal = !!data?.isLocal;
        const address = data?.address;
        const devBypass = isLocal && process.env.NEXUSLINK_DEV === '1';
        sessions.set(id, { ws, isLocal, address, authenticated: devBypass });
      },
      async message(ws, raw) {
        let msg: WsMessage;
        try {
          msg = JSON.parse(raw as unknown as string) as WsMessage;
        } catch {
          return;
        }
        if (msg.type === 'rpc-request') {
          try {
            await dispatch(msg.request.method, (msg.request.params as Params) ?? {}, msg.request, ws);
          } catch (err) {
            console.error('RPC Error:', err);
            const response: RpcResponse = { id: msg.request.id, error: String(err) };
            send(ws, { type: 'rpc-response', response });
          }
        }
      },
      close(ws) {
        killTerminalsForSocket(ws as unknown as WebSocket);
        stopCapturesForSocket(ws as unknown as WebSocket);
        sessions.forEach((s, id) => {
          if (s.ws === ws) sessions.delete(id);
        });
      },
    },
  });

  startPerfBroadcast(send, getPerfSnapshot, getAuthenticatedSessions);
  if (!tailscaleOnly && bindHost === '0.0.0.0') {
    startMdns(port);
  }
  ensureFirewallRule(port);
  startTray();

  const servesClient = await staticAvailable();
  printLaunchBanner(port, servesClient);
  console.log(`[windows-host] listening on ${bindHost}:${server.port}`);
  return { port: server.port };
}

if (import.meta.main) {
  startRpcServer(45678).catch(console.error);
  process.on('exit', () => stopTray());
}
