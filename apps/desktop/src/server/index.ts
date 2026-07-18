import type { WsMessage, RpcRequest, RpcResponse, RpcMethod } from '@nexuslink/rpc-types';
import { handleFsList } from './handlers/fs';
import { listProcesses } from './handlers/process';
import { getSystemInfo, getPerfSnapshot } from './handlers/system';
import { handleTerminalCreate, handleTerminalInput, handleTerminalResize, handleTerminalKill, setSend as setTerminalSend } from './handlers/terminal';
import { validateToken, generateToken, handleSessionPair, validateSessionTOTP, isLocalDev, generateDevToken } from './handlers/auth';
import { setSend as setSignalingSend } from './handlers/signaling';
import { mouseMove, mouseClick, mouseScroll, keyEvent, typeText, buttonDown, buttonUp, mouseMoveAbs } from './handlers/input';
import { setSend as setCaptureSend, startCapture, stopCapture, stopCapturesForSocket, getScreenMetadata } from './handlers/capture';
import { listWindows, listApps, launchApp, adoptWindow, releaseWindow, activateWindow, getWindowGeometry } from './handlers/windows';
import { serveStatic, staticAvailable } from './static-server';
import { printLaunchBanner } from './launch-banner';
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
  setCaptureSend(send);

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
      case 'input.mouseMove':
        result = mouseMove(params.dx as number, params.dy as number);
        break;
      case 'input.mouseClick':
        result = mouseClick(
          params.button as 'left' | 'right' | 'middle',
          params.x as number | undefined,
          params.y as number | undefined,
        );
        break;
      case 'input.mouseScroll':
        result = mouseScroll(
          params.deltaX as number,
          params.deltaY as number,
          params.x as number | undefined,
          params.y as number | undefined,
          params.modifiers as string[] | undefined,
        );
        break;
      case 'input.buttonDown':
        result = buttonDown(
          params.button as 'left' | 'right' | 'middle',
          params.x as number | undefined,
          params.y as number | undefined,
        );
        break;
      case 'input.buttonUp':
        result = buttonUp(
          params.button as 'left' | 'right' | 'middle',
          params.x as number | undefined,
          params.y as number | undefined,
        );
        break;
      case 'input.mouseMoveAbs':
        result = mouseMoveAbs(params.x as number, params.y as number);
        break;
      case 'input.keyEvent':
        result = keyEvent(params.key as string, params.modifiers as string[] | undefined);
        break;
      case 'input.typeText':
        result = typeText(params.text as string);
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
      case 'apps.launch':
        result = await launchApp(params.appId as string);
        break;
      case 'screen.startCapture': {
        // Per-window capture: resolve the window's current on-screen rect, grab
        // only that region, and keep tracking the window if it moves.
        const windowId = params.windowId as string | undefined;
        const region = windowId ? getWindowGeometry(windowId) ?? undefined : undefined;
        result = startCapture(
          (params.quality as 'low' | 'medium' | 'high') ?? 'medium',
          (params.fps as number) ?? 12,
          ws,
          region,
          windowId ? () => getWindowGeometry(windowId) : undefined,
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
    async fetch(req, srv) {
      const url = new URL(req.url);
      if (url.pathname === '/signal' || url.pathname === '/rpc') {
        const isLocal = isLocalDev(req.url);
        // @ts-expect-error Bun upgrade supports data option in runtime
        if (srv.upgrade(req, { data: { isLocal } })) return;
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
        sessions.forEach((s, id) => {
          if (s.ws === ws) sessions.delete(id);
        });
      },
    },
  });

  startSidecarReader(send, getPerfSnapshot, getAuthenticatedSessions);

  const servesClient = await staticAvailable();
  printLaunchBanner(port, servesClient);
  console.log(`[rpc-server] listening on port ${port}`);
  return { port };
}

// Start the server if this file is run directly
if (import.meta.main) {
  startRpcServer(45678).catch(console.error);
}
