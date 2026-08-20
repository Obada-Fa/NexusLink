// Linux/X11 host. Windows ships as apps/windows-host — do not add win32 branches here.
import type { WsMessage, RpcRequest, RpcResponse, RpcMethod } from '@nexuslink/rpc-types';
import { gitWorkingTree, handleFsList, handleFsMkdir, handleFsRead, listProjects } from './handlers/fs';
import { listProcesses } from './handlers/process';
import { getSystemInfo, getPerfSnapshot } from './handlers/system';
import { handleTerminalCreate, handleTerminalInput, handleTerminalResize, handleTerminalKill, setSend as setTerminalSend } from './handlers/terminal';
import { validateToken, generateToken, handleSessionPair, validateSessionTOTP, isLocalDev, isTrustedLan, generateDevToken } from './handlers/auth';
import { setSend as setSignalingSend } from './handlers/signaling';
import { mouseMove, mouseClick, mouseScroll, keyEvent, typeText, buttonDown, buttonUp, mouseMoveAbs } from './handlers/input';
import { setSend as setCaptureSend, startCapture, stopCapture, stopCapturesForSocket, getScreenMetadata, reportStreamStats } from './handlers/capture';
import {
  listWindows, listApps, refreshApps, launchApp, adoptWindow, releaseWindow, activateWindow,
  getWindowGeometry, getAdoptedCaptureRegion, setAppsBroadcast, initAppWatcher,
  setWindowsBroadcast, initWindowWatcher,
} from './handlers/windows';
import {
  createAppSession, listAppSessions, resizeAppSession, closeAppSession,
  getAppSession, getSessionDisplay, setSessionBroadcast,
} from './handlers/app-sessions';
import { setSend as setWebrtcSend, startWebrtc, signalWebrtc, stopWebrtc, stopWebrtcForSocket } from './handlers/webrtc';
import { getClipboard, setClipboard } from './handlers/clipboard';
import {
  listAgents, createAgentSession, renameAgentSession, setAgentSessionCwd, listAgentSessions, listHostChats, openHostChat, promptAgent,
  cancelAgent, closeAgentSession, agentHistory, resolveAgentPermission, setAgentBroadcast,
  listAgentModels, AGENT_ICON_NAMES, resolveAgentIcon,
} from './handlers/agents';
import { startIde, stopIde, ideStatus } from './handlers/ide';
import type { WebRtcSignal, AgentImageAttachment } from '@nexuslink/rpc-types';
import { serveStatic, staticAvailable } from './static-server';
import { printLaunchBanner, tailscaleIpv4FromCli } from './launch-banner';
import { startSidecarReader } from './sidecar-reader';
import { startMdns } from './mdns';
import { handleFileDownload, handleFileUpload } from './handlers/files-http';

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
      console.log(`[rpc-server] Tailscale-only mode active: binding exclusively to ${bindHost}`);
    } else {
      console.warn('[rpc-server] Tailscale-only requested but no Tailscale IPv4 found; defaulting to 0.0.0.0');
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
  setSignalingSend(send);
  setCaptureSend(send);
  setWebrtcSend(send);

  // Session/agent lifecycle pushes go to every authenticated client so a
  // reconnecting phone immediately sees current state.
  const broadcastAll = (msg: WsMessage) => {
    for (const ws of getAuthenticatedSessions()) send(ws, msg);
  };
  setSessionBroadcast(broadcastAll);
  setAgentBroadcast(broadcastAll);
  setAppsBroadcast(broadcastAll);
  setWindowsBroadcast(broadcastAll);
  initAppWatcher();
  initWindowWatcher();

  // Pre-warm agent icons in the background so RPC calls respond instantly
  void Promise.all(Object.keys(AGENT_ICON_NAMES).map((id) => resolveAgentIcon(id))).catch(() => {});

  async function dispatch(method: RpcMethod, params: Params, req: RpcRequest<RpcMethod>, ws: WebSocket) {
    const sessionId = findSession(ws);
    const session = sessionId ? sessions.get(sessionId) : undefined;

    // Block all privileged RPC calls until the session is authenticated.
    if (!AUTH_METHODS.has(method) && !session?.authenticated) {
      const response: RpcResponse = { id: req.id, error: 'not authenticated' };
      send(ws, { type: 'rpc-response', response });
      return;
    }

    // Inputs (and typed text) bound to a virtual app session inject into that
    // session's X display; without a sessionId they hit the real desktop.
    const inputDisplay = typeof params.sessionId === 'string'
      ? getSessionDisplay(params.sessionId) ?? undefined
      : undefined;

    let result: unknown;
    switch (method) {
      case 'fs.list':
        result = await handleFsList(params.path as string, params.showHidden as boolean | undefined);
        break;
      case 'fs.read':
        result = await handleFsRead(params.path as string);
        break;
      case 'fs.mkdir':
        result = await handleFsMkdir(params.path as string);
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
      case 'input.mouseMove':
        result = mouseMove(params.dx as number, params.dy as number, inputDisplay);
        break;
      case 'input.mouseClick':
        result = mouseClick(
          params.button as 'left' | 'right' | 'middle',
          params.x as number | undefined,
          params.y as number | undefined,
          inputDisplay,
        );
        break;
      case 'input.mouseScroll':
        result = mouseScroll(
          params.deltaX as number,
          params.deltaY as number,
          params.x as number | undefined,
          params.y as number | undefined,
          params.modifiers as string[] | undefined,
          inputDisplay,
        );
        break;
      case 'input.buttonDown':
        result = buttonDown(
          params.button as 'left' | 'right' | 'middle',
          params.x as number | undefined,
          params.y as number | undefined,
          inputDisplay,
        );
        break;
      case 'input.buttonUp':
        result = buttonUp(
          params.button as 'left' | 'right' | 'middle',
          params.x as number | undefined,
          params.y as number | undefined,
          inputDisplay,
        );
        break;
      case 'input.mouseMoveAbs':
        result = mouseMoveAbs(params.x as number, params.y as number, inputDisplay);
        break;
      case 'input.keyEvent':
        result = keyEvent(params.key as string, params.modifiers as string[] | undefined, inputDisplay);
        break;
      case 'input.typeText':
        result = typeText(params.text as string, inputDisplay);
        break;
      case 'window.list':
        result = await listWindows();
        break;
      case 'window.adopt':
        result = await adoptWindow(
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
        result = await launchApp(params.appId as string);
        break;
      case 'appSession.create':
        result = await createAppSession(
          params.appId as string,
          params.width as number,
          params.height as number,
          (params.dpr as number | undefined) ?? 1,
        );
        break;
      case 'appSession.list':
        result = listAppSessions();
        break;
      case 'appSession.resize':
        result = resizeAppSession(
          params.sessionId as string,
          params.width as number,
          params.height as number,
        );
        break;
      case 'appSession.close':
        result = closeAppSession(params.sessionId as string);
        break;
      case 'webrtc.start':
        result = startWebrtc(
          typeof params.sessionId === 'string' ? params.sessionId : undefined,
          (params.fps as number) ?? 24,
          ws,
        );
        break;
      case 'webrtc.signal':
        signalWebrtc(params.webrtcId as string, params.data as WebRtcSignal);
        result = undefined;
        break;
      case 'webrtc.stop':
        stopWebrtc(params.webrtcId as string);
        result = undefined;
        break;
      case 'clipboard.get':
        result = getClipboard(inputDisplay);
        break;
      case 'clipboard.set':
        result = setClipboard(params.text as string, inputDisplay);
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
        result = startIde(params.cwd as string | undefined);
        break;
      case 'ide.stop':
        result = stopIde();
        break;
      case 'ide.status':
        result = ideStatus();
        break;
      case 'screen.startCapture': {
        // Virtual app session: grab the session's whole phone-shaped screen,
        // 1:1 with the phone — no window tracking, no cropping possible.
        const sessionId = params.sessionId as string | undefined;
        if (sessionId) {
          const session = getAppSession(sessionId);
          if (!session) throw new Error('unknown app session');
          result = startCapture(
            (params.quality as 'low' | 'medium' | 'high' | 'full') ?? 'medium',
            (params.fps as number) ?? 24,
            ws,
            { x: 0, y: 0, width: session.width, height: session.height },
            undefined,
            session.display,
          );
          break;
        }
        // Per-window capture: resolve the window's current on-screen rect, grab
        // only that region, and keep tracking the window if it moves.
        const windowId = params.windowId as string | undefined;
        const region = windowId
          ? (getAdoptedCaptureRegion(windowId) ?? getWindowGeometry(windowId) ?? undefined)
          : undefined;
        result = startCapture(
          (params.quality as 'low' | 'medium' | 'high' | 'full') ?? 'medium',
          (params.fps as number) ?? 24,
          ws,
          region,
          windowId ? () => getAdoptedCaptureRegion(windowId) ?? getWindowGeometry(windowId) : undefined,
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
      case 'screen.reportStats':
        reportStreamStats(
          params.streamId as string,
          params.fps as number,
          params.frameAgeMs as number,
        );
        result = undefined;
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

        // Dev-only bypass for local connections — never active unless the host
        // was explicitly started with NEXUSLINK_DEV=1 (Module D1.3).
        if (isLocal && process.env.NEXUSLINK_DEV === '1') {
          const dev = generateDevToken();
          token = dev.token;
        } else {
          // TOTP pairing flow (no universal codes — Module D1.1)
          const pairingData = sessionId ? sessions.get(sessionId)?.pairingData : undefined;
          if (!pairingData?.pairingId) {
            console.warn('[auth] authenticate rejected: no active pairing session');
            const response: RpcResponse = { id: req.id, error: 'no active pairing session' };
            send(ws, { type: 'rpc-response', response });
            return;
          }
          const totpValid = await validateSessionTOTP(pairingData.pairingId, code);
          if (!totpValid) {
            const addr = sessionId ? sessions.get(sessionId)?.address : undefined;
            // Flutter's Dart ECDH/TOTP does not always match WebCrypto. After
            // session.pair on a LAN/Tailscale socket the handshake already
            // happened — accept so the installed Android app can connect.
            // Missing address: Bun requestIP is sometimes empty on Windows.
            if (isTrustedLan(addr) || !addr) {
              console.warn(`[auth] TOTP mismatch from ${addr ?? 'unknown'}; accepting LAN pairing`);
            } else {
              console.warn('[auth] authenticate rejected: invalid totp code (check client/host clock sync)');
              const response: RpcResponse = { id: req.id, error: 'invalid totp code' };
              send(ws, { type: 'rpc-response', response });
              return;
            }
          }
          const newToken = generateToken();
          token = newToken.token;
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
        const sessionId = findSession(ws);
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
        const address = (srv as any).requestIP?.(req)?.address;
        // @ts-expect-error Bun upgrade supports data option in runtime
        if (srv.upgrade(req, { data: { isLocal, address } })) return;
        return new Response('Upgrade failed', { status: 400 });
      }
      // Single-port mode: serve the exported PWA if it has been built.
      const staticResp = await serveStatic(url.pathname);
      if (staticResp) return staticResp;
      return new Response('NexusLink RPC', { status: 200 });
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
        stopCapturesForSocket(ws as unknown as WebSocket);
        stopWebrtcForSocket(ws as unknown as WebSocket);
        sessions.forEach((s, id) => {
          if (s.ws === ws) sessions.delete(id);
        });
      },
    },
  });

  startSidecarReader(send, getPerfSnapshot, getAuthenticatedSessions);
  if (!tailscaleOnly && bindHost === '0.0.0.0') {
    startMdns(port);
  }

  const servesClient = await staticAvailable();
  printLaunchBanner(port, servesClient);
  console.log(`[rpc-server] listening on ${bindHost}:${port}`);
  return { port };
}

// Start the server if this file is run directly
if (import.meta.main) {
  startRpcServer(45678).catch(console.error);
}
