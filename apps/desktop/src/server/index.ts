import { getCursorHint } from './handlers/cursor';
import { initializeAgentStore, storedHistory, storedActivity, storedActivityV2, activityOperation, setActivityBroadcast, closeAgentStore, flushAgents } from './workspace/agent-store';
import { archiveAgentSession, pendingAgentApprovals } from './handlers/agents';
import { enroll, resume, accessToken, hostId, WorkspaceError, stringParam, isPrivatePeer } from './workspace/security';
import { workspaceRequest, validateRequest, once } from './workspace/protocol';
import { createChatLibrary } from './workspace/chat-library';
import { ApprovalBridge } from './handlers/approval-bridge';
import { roots as providerRoots } from '../../../../packages/chat-core/src/paths';
import { join as joinPath } from 'node:path';
import { petSummaries } from './workspace/pet-monitor';
import { dataDirectory } from './workspace/security';
import { closeSecurityStore } from './workspace/security';
import { setChatLibraryReady } from './workspace/protocol';
import { detachTerminalsForSocket, stopAllTerminals } from './handlers/terminal';
// Linux/X11 host. Windows ships as apps/windows-host — do not add win32 branches here.
import type { WsMessage, RpcRequest, RpcResponse, RpcMethod } from '@nexuslink/rpc-types';
import { gitWorkingTree, handleFsList, handleFsMkdir, handleFsRead, listProjects, handleFsDelete, handleFsMove } from './handlers/fs';
import { listProcesses, killProcess } from './handlers/process';
import { getSystemInfo, getPerfSnapshot } from './handlers/system';
import { getVitals } from './handlers/vitals';
import { listAgentApps, agentAppAction } from './handlers/agent-apps';
import { remoteHealth, restartRustdesk, startRemoteWatchdog } from './handlers/remote-access';
import type { MonitorSnapshot } from '@nexuslink/rpc-types';
import { handleTerminalCreate, handleTerminalInput, handleTerminalResize, handleTerminalKill, setSend as setTerminalSend } from './handlers/terminal';
import { validateToken } from './handlers/auth';
import { setSend as setSignalingSend } from './handlers/signaling';
import { mouseMove, mouseClick, mouseScroll, keyEvent, typeText, buttonDown, buttonUp, mouseMoveAbs } from './handlers/input';
import { setSend as setCaptureSend, setCaptureAuthorizer, listMonitors, startCapture, stopCapture, stopCapturesForSocket, getScreenMetadata, reportStreamStats, setStreamQuality } from './handlers/capture';
import {
  listWindows, listApps, refreshApps, launchApp, adoptWindow, releaseWindow, activateWindow, closeWindow,
  getWindowGeometry, getAdoptedCaptureRegion, setAppsBroadcast, initAppWatcher,
  setWindowsBroadcast, initWindowWatcher,
} from './handlers/windows';
import {
  createAppSession, listAppSessions, resizeAppSession, closeAppSession,
  getAppSession, getSessionDisplay, setSessionBroadcast,
} from './handlers/app-sessions';
import { setSend as setWebrtcSend, startWebrtc, signalWebrtc, stopWebrtc, stopWebrtcForSocket } from './handlers/webrtc';
import { readClipboard, setClipboard } from './handlers/clipboard';
import { micStatus, startMic, stopMic, stopMicForSocket, handleMicFrame, setMicAuthorizer, unloadMicDevice } from './handlers/mic';
import {
  listAgents, createAgentSession, renameAgentSession, setAgentSessionCwd, listAgentSessions, listHostChats, openHostChat, promptAgent,
  cancelAgent, closeAgentSession, agentHistory, resolveAgentPermission, setAgentBroadcast,
  listAgentModels, AGENT_ICON_NAMES, resolveAgentIcon, setAgentApprovalMode,
} from './handlers/agents';
import { startIde, stopIde, ideStatus } from './handlers/ide';
import type { WebRtcSignal, AgentImageAttachment } from '@nexuslink/rpc-types';
import { serveStatic, staticAvailable } from './static-server';
import { printLaunchBanner, tailscaleIpv4FromCli } from './launch-banner';
import { startSidecarReader } from './sidecar-reader';
import { startMdns } from './mdns';
import { handleFileDownload, handleFileUpload } from './handlers/files-http';
import {
  registerPushToken, listPushTokens, removePushToken, sendTestPush, setPushActiveSessionsCheck, sendAgentPushNotification,
} from './handlers/push';

type Params = Record<string, unknown>;

type Session = {
  ws: WebSocket;
  token?: string;
  pairingData?: { pairingId: string };
  isLocal?: boolean;
  address?: string;
  authenticated: boolean;
  topics?: Set<string>;
  metricsInterval?: number;
  lastMetric?: number;
  monitorInterval?: number;
  lastMonitor?: number;
  role?: string;
};

const AUTH_METHODS = new Set<string>([
  'session.hello',
  'session.enroll',
  'session.resume',
  'session.pair',
  'session.authenticate',
  'session.disconnect',
]);

export async function startRpcServer(port = 45678, hostname?: string) {
  const sessions = new Map<string, Session>();
  const taskMutations = new Map<string, Promise<unknown>>();
  async function withTaskMutation<T>(task:string, action:()=>Promise<T>):Promise<T> {
    const previous=taskMutations.get(task) ?? Promise.resolve();
    const run=previous.catch(()=>{}).then(action);
    taskMutations.set(task,run);
    try {return await run;} finally {if(taskMutations.get(task)===run)taskMutations.delete(task);}
  }

  let lastSnapshot: MonitorSnapshot | null = null;
  /** Vitals + agent apps + remote health in one payload; shared by all subscribers for 900 ms. */
  function monitorSnapshot(fresh = false): MonitorSnapshot {
    if (!fresh && lastSnapshot && Date.now() - lastSnapshot.at < 900) return lastSnapshot;
    const vitals = getVitals();
    const { apps, launchers } = listAgentApps();
    lastSnapshot = { at: Date.now(), vitals, apps, launchers, remote: remoteHealth() };
    return lastSnapshot;
  }

  let bindHost = hostname ?? process.env.NEXUSLINK_HOST ?? process.env.HOST;
  const tailscaleOnly = process.env.NEXUSLINK_TAILSCALE_ONLY === '1' || process.env.TAILSCALE_ONLY === '1';

  if (!bindHost && tailscaleOnly) {
    // At boot the user service can start before tailscaled has an address. Wait for it
    // rather than exiting into a restart loop (or, worse, staying alive with no listener).
    let tsIps = tailscaleIpv4FromCli();
    for (let waited = 0; tsIps.length === 0 && waited < 120; waited += 3) {
      if (waited === 0) console.log('[rpc-server] waiting for Tailscale to come up…');
      await Bun.sleep(3000);
      tsIps = tailscaleIpv4FromCli();
    }
    if (tsIps.length > 0) {
      bindHost = tsIps[0];
      console.log(`[rpc-server] Tailscale-only mode active: binding exclusively to ${bindHost}`);
    } else {
      throw new Error('Tailscale-only mode requires an active Tailscale IPv4 address. Start Tailscale, then restart NexusLink.');
    }
  }

  if (tailscaleOnly && bindHost) {
    const tailnet = tailscaleIpv4FromCli();
    if (!tailnet.includes(bindHost)) throw new Error('Tailscale-only mode can bind only to an active Tailscale address. Start Tailscale or correct NEXUSLINK_HOST.');
  }
  bindHost = bindHost ?? '0.0.0.0';
  await initializeAgentStore();
  const chats = await createChatLibrary(dataDirectory(), hostId(), (connection, revision) => {
    const ws = connection as WebSocket;
    const id = findSession(ws);
    if (id && sessions.get(id)?.role !== 'monitor') send(ws, { type: 'chat-library-update', revision });
  });
  setChatLibraryReady(true);

  function send(ws: WebSocket, msg: WsMessage) {
    // Handshake and RPC errors must still reach an unauthenticated socket.
    // Every unsolicited event needs a current credential at delivery time,
    // including PTY output queued after an attach or during revocation.
    if (msg.type !== 'rpc-response') {
      const id = findSession(ws);
      const session = id ? sessions.get(id) : undefined;
      if (!session?.authenticated || !(accessToken(session.token) ||
          (session.isLocal && process.env.NEXUSLINK_DEV === '1' && validateToken(session.token || '')))) {
        detachTerminalsForSocket(ws);
        stopCapturesForSocket(ws);
        stopWebrtcForSocket(ws);
        stopMicForSocket(ws);
        if (ws.readyState === 1) ws.close(1008, 'Authorization expired');
        return;
      }
    }
    if (ws.readyState === 1) {
      if ((ws as any).getBufferedAmount?.() > 4 * 1024 * 1024) { ws.close(1013, 'Client too slow; reconnect to replay'); return; }
      ws.send(JSON.stringify(msg));
    }
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
      if (s.token && (accessToken(s.token) || (s.isLocal && process.env.NEXUSLINK_DEV === '1' && validateToken(s.token))) && s.ws.readyState === 1) {
        list.push(s.ws);
      }
    });
    return list;
  }

  setTerminalSend(send);
  setSignalingSend(send);
  setCaptureSend(send);
  // Binary frames bypass send(); re-check the credential on every frame so a stream
  // stops when the token expires or the phone is revoked.
  const controlAuthorized = (ws: WebSocket) => {
    const id = findSession(ws);
    const s = id ? sessions.get(id) : undefined;
    return !!s?.authenticated && s.role !== 'monitor' && !!(accessToken(s.token) || (s.isLocal && process.env.NEXUSLINK_DEV === '1' && validateToken(s.token || '')));
  };
  setCaptureAuthorizer(controlAuthorized);
  setMicAuthorizer(controlAuthorized);
  setWebrtcSend(send);
  setActivityBroadcast(record=>{
    for(const s of sessions.values())if(s.topics?.has('activity'))send(s.ws,{type:'activity-update',record});
  });

  // Session/agent lifecycle pushes go to every authenticated client so a
  // reconnecting phone immediately sees current state.
  const broadcastAll = (msg: WsMessage) => {
    for (const ws of getAuthenticatedSessions()) {
      const s = sessions.get(findSession(ws)!);
      if (s?.role === 'monitor' && s.topics?.has('agents')) {
        if (msg.type === 'agent-session-update' || msg.type === 'agent-session-deleted') send(ws, msg);
        if (msg.type === 'agent-event' && ['result','error','permission-request','status'].includes(msg.event.kind)) send(ws, { ...msg, event: { ...msg.event, text: undefined, toolInput: undefined, toolOutput: undefined } });
      } else if (s?.role !== 'monitor' && ((msg.type.startsWith('agent-') && s?.topics?.has('agents')) || ((msg.type === 'windows-update' || msg.type === 'apps-update') && s?.topics?.has('windows')) || !msg.type.endsWith('-update') && msg.type !== 'agent-event')) send(ws, msg);
    }
  };
  setSessionBroadcast(broadcastAll);
  setAgentBroadcast(broadcastAll);
  setAppsBroadcast(broadcastAll);
  setWindowsBroadcast(broadcastAll);
  setPushActiveSessionsCheck(() => getAuthenticatedSessions().length > 0);
  // Phone approvals for Claude sessions started outside NexusLink (opt-in hook, loopback only).
  const approvals = new ApprovalBridge({
    dataDir: dataDirectory(), hostId: hostId(),
    claudeSettingsPath: joinPath(providerRoots().claude, 'settings.json'),
    desktopSessionsDir: joinPath(providerRoots().claudeDesktop, 'claude-code-sessions'),
    onChange: items => broadcastAll({ type: 'approvals-changed', items }),
    push: item => void sendAgentPushNotification({
      title: item.kind === 'question' ? 'Claude is asking you' : item.kind === 'plan' ? 'Claude has a plan to approve' : 'Claude needs approval',
      body: item.title, kind: 'external-approval',
    }),
  }).start();


  // Agent icons load only when requested; normal coding startup does no desktop work.

  async function dispatch(method: string, params: Params, req: RpcRequest<RpcMethod>, ws: WebSocket) {
    const sessionId = findSession(ws);
    const session = sessionId ? sessions.get(sessionId) : undefined;

    // Block all privileged RPC calls until the session is authenticated.
    if (!AUTH_METHODS.has(method) && (!session?.authenticated || !(accessToken(session.token) || (session.isLocal && process.env.NEXUSLINK_DEV === '1' && validateToken(session.token || ''))))) {
      const response: RpcResponse = { id: req.id, error: 'Authentication expired. Reconnect to the PC.', code: 'UNAUTHENTICATED' };
      send(ws, { type: 'rpc-response', response });
      return;
    }

    validateRequest(method, params);
    if (session?.role === 'monitor' && !AUTH_METHODS.has(method) && !['session.subscribe','session.getCapabilities','session.heartbeat','agent.listSessions','activity.snapshot','activity.snapshotV2','activity.monitor','activity.action','activity.actionStatus'].includes(method)) throw new WorkspaceError('PERMISSION_DENIED','Monitoring connections only receive task status and scoped notification actions.');
    if (method === 'session.hello') { send(ws, {type:'rpc-response',response:{id:req.id,result:{protocolVersion:2}}}); return; }
    if (method === 'session.enroll' || method === 'session.resume') {
      const result = method === 'session.enroll' ? enroll(stringParam(params,'code'),stringParam(params,'name')) : resume(stringParam(params,'credential'),params.role === 'monitor' ? 'monitor':'control');
      if (session) { session.token=result.token; session.authenticated=true; session.role=params.role === 'monitor' ? 'monitor':'control'; }
      send(ws,{type:'rpc-response',response:{id:req.id,result}}); return;
    }
    if (method === 'session.subscribe') {
      if (session) {
        const topics = params.topics;
        if (!Array.isArray(topics) || topics.some(t=> !['agents','windows','metrics','activity','monitor'].includes(t as string))) throw new WorkspaceError('INVALID_ARGUMENT','Invalid subscriptions.');
        session.topics = new Set(topics as string[]);
        session.metricsInterval=params.metricsInterval===2000?2000:5000;
        session.monitorInterval=params.monitorInterval===1000?1000:params.monitorInterval===5000?5000:2000;
        if(session.role === 'monitor') session.topics=new Set(['agents',...(topics.includes('activity')?['activity']:[])]);
      }
      send(ws,{type:'rpc-response',response:{id:req.id,result:{ok:true}}}); return;
    }
    if (method === 'activity.monitor') {
      // Keep discovery alive while a background phone is connected. Expose only
      // bounded summaries: monitor credentials still cannot read transcripts.
      chats.subscribe(ws, true);
      const pages = await Promise.all(['claude', 'codex', 'antigravity', 'opencode', 'cursor'].map(source => chats.list({source, limit: 50, archived: false, sort: 'monitor'})));
      const items = petSummaries(pages.flatMap(page => page.items));
      send(ws, {type: 'rpc-response', response: {id: req.id, result: {items, sources: pages[0].sources}}}); return;
    }
    if (method.startsWith('chat.')) {
      const result = await chats.request(method, params, ws, accessToken(session?.token)?.deviceId || 'development');
      send(ws, { type: 'rpc-response', response: { id: req.id, result } }); return;
    }
    const extra = await workspaceRequest(method,params,ws,accessToken(session?.token)?.deviceId || 'development');
    if (extra.handled) { send(ws,{type:'rpc-response',response:{id:req.id,result:extra.result}}); return; }

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
        result = await listProcesses({ limit: typeof params.limit === 'number' ? params.limit : undefined });
        break;
      case 'process.kill': {
        const pid = Number(params.pid);
        if (!Number.isSafeInteger(pid) || pid <= 1) throw new WorkspaceError('INVALID_ARGUMENT', 'Invalid process ID.');
        result = await killProcess(pid, params.force === true);
        break;
      }
      case 'fs.delete':
        result = await handleFsDelete(stringParam(params, 'path'), params.recursive === true);
        break;
      case 'fs.move':
        result = await handleFsMove(stringParam(params, 'from'), stringParam(params, 'to'));
        break;
      case 'screen.listMonitors':
        result = listMonitors({ fresh: true });
        break;
      case 'terminal.create':
        result = await once(accessToken(session?.token)?.deviceId || 'development', method, params, () => handleTerminalCreate(
          params.cols as number,
          params.rows as number,
          params.shell as string | undefined,
          ws,
          params.cwd as string | undefined,
          { detached: params.detached === true, taskId: params.taskId as string | undefined },
        ));
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
      case 'system.getVitals':
        result = getVitals();
        break;
      case 'monitor.snapshot':
        result = monitorSnapshot(true);
        break;
      case 'monitor.appAction': {
        const action = stringParam(params, 'action');
        if (!['restart', 'quit', 'kill', 'focus', 'launch'].includes(action)) throw new WorkspaceError('INVALID_ARGUMENT', 'Invalid app action.');
        result = await agentAppAction({ instanceId: stringParam(params, 'instanceId', true) || undefined, appId: stringParam(params, 'appId', true) || undefined, action: action as any });
        lastSnapshot = null;
        break;
      }
      case 'monitor.remoteAction': {
        const service = stringParam(params, 'service');
        const action = stringParam(params, 'action');
        if (service !== 'rustdesk' || !['restart', 'repair'].includes(action)) throw new WorkspaceError('INVALID_ARGUMENT', 'Only RustDesk can be restarted from the phone.');
        result = await restartRustdesk(`phone: ${action}`);
        lastSnapshot = null;
        break;
      }
      case 'input.cursorHint': {
        const requestedSession = params.sessionId === undefined ? undefined : stringParam(params, 'sessionId');
        const display = requestedSession ? getSessionDisplay(requestedSession) : undefined;
        if (requestedSession && !display) throw new WorkspaceError('INVALID_ARGUMENT', 'Stream session is unavailable.');
        const windowId = params.windowId === undefined ? '' : stringParam(params, 'windowId');
        if (windowId && !/^(0x[0-9a-fA-F]+|[0-9]+)$/.test(windowId)) throw new WorkspaceError('INVALID_ARGUMENT', 'Invalid stream window.');
        result = await getCursorHint(display, windowId);
        break;
      }
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
      case 'window.close':
        result = closeWindow(params.windowId as string);
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
        result = await readClipboard(inputDisplay);
        break;
      case 'clipboard.set':
        result = setClipboard(params.text as string, inputDisplay);
        break;
      case 'agent.pendingApprovals':
        result=pendingAgentApprovals(stringParam(params,'agentSessionId')); break;
      case 'agent.historyPage':
        result=await storedHistory(stringParam(params,'agentSessionId'),params); break;
      case 'agent.archive':
        result=await archiveAgentSession(stringParam(params,'agentSessionId'),params.archived!==false); break;
      case 'activity.snapshot':
        result={sessions:listAgentSessions(),...await storedActivity(Number(params.cursor)||0)}; break;
      case 'activity.snapshotV2':
        result=await storedActivityV2(Number(params.cursor)||0,params.throughCursor===undefined?undefined:Number(params.throughCursor)); break;
      case 'activity.actionStatus': {
        const device=accessToken(session?.token)?.deviceId || 'development';
        result=await activityOperation('status',{device,operationId:params.operationId});
        if(!result)throw new WorkspaceError('NOT_FOUND','Notification action operation was not found.');
        break;
      }
      case 'activity.action': {
        const device=accessToken(session?.token)?.deviceId || 'development';
        const task=stringParam(params,'agentSessionId');
        result=await withTaskMutation(task,async()=>{
          const operationId=stringParam(params,'operationId');
          const args=JSON.stringify({hostId:params.hostId,agentSessionId:task,expectedTurnId:params.expectedTurnId,sourceCursor:params.sourceCursor,action:params.action,requestId:params.requestId,text:params.text});
          const claimed=await activityOperation('claim',{device,operationId,args});
          if(!claimed.fresh)return claimed;
          try {
            if(params.hostId!==hostId())throw new WorkspaceError('INVALID_ARGUMENT','Notification belongs to another host.');
            const source=await activityOperation('source',{sourceCursor:params.sourceCursor});
            if(!source || source.hostId!==hostId() || source.agentSessionId!==task || source.turnId!==params.expectedTurnId || !source.availableActions?.includes(params.action))throw new WorkspaceError('STALE_ACTION','Notification is no longer actionable.');
            if(params.action!=='reply' && source.requestId!==params.requestId)throw new WorkspaceError('STALE_ACTION','Approval request has changed.');
            const current=listAgentSessions().find(s=>s.agentSessionId===task);
            if(!current || current.archived || current.status!=='running' || current.turnId!==params.expectedTurnId)throw new WorkspaceError('STALE_ACTION','Task or turn has changed.');
            if(params.action==='reply' && (current.busy || !['idle','completed','failed'].includes(current.taskState || '')))throw new WorkspaceError('STALE_ACTION','Task is not ready for a reply.');
            if(params.action!=='reply' && !pendingAgentApprovals(task).some(e=>e.refId===params.requestId && e.turnId===params.expectedTurnId))throw new WorkspaceError('STALE_ACTION','Approval is no longer pending.');
          }catch(error){
            return await activityOperation('reject',{device,operationId,reason:error instanceof Error?error.message:'Action no longer available'});
          }
          await activityOperation('dispatching',{device,operationId});
          try {
            const accepted=params.action==='reply'
              ? promptAgent(task,String(params.text))
              : resolveAgentPermission(task,String(params.requestId),params.action==='approve');
            const state=accepted.ok?'succeeded':'rejected';
            return await activityOperation('finish',{device,operationId,state,reason:accepted.reason});
          }catch(error){
            return await activityOperation('finish',{device,operationId,state:'uncertain',reason:error instanceof Error?error.message:'Delivery outcome unknown'});
          }
        });
        break;
      }
      case 'agent.list':
        result = listAgents();
        break;
      case 'agent.createSession':
        result = await once(accessToken(session?.token)?.deviceId || 'development',method,params,()=>createAgentSession(
          params.agent as string,
          params.cwd as string | undefined,
          params.title as string | undefined,
        ));
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
        result = listAgentModels(params.agent as string, params.refresh === true);
        break;
      case 'agent.prompt':
        result = await withTaskMutation(String(params.agentSessionId),()=>once(accessToken(session?.token)?.deviceId || 'development',method,params,()=>promptAgent(
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
        )));
        break;
      case 'agent.permission':
        result = await withTaskMutation(String(params.agentSessionId),async()=>resolveAgentPermission(
          params.agentSessionId as string,
          params.requestId as string,
          params.allow as boolean,
        ));
        break;
      case 'agent.setApprovalMode':
        result = setAgentApprovalMode(
          params.agent as string,
          (params.mode as string) ?? '',
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
        if (windowId) {
          const region =
            getAdoptedCaptureRegion(windowId) ?? getWindowGeometry(windowId);
          if (!region || region.width < 16 || region.height < 16) {
            throw new Error('window is gone or has no geometry');
          }
          result = startCapture(
            (params.quality as 'low' | 'medium' | 'high' | 'full') ?? 'medium',
            (params.fps as number) ?? 24,
            ws,
            region,
            () => getAdoptedCaptureRegion(windowId) ?? getWindowGeometry(windowId),
          );
          break;
        }
        result = startCapture(
          (params.quality as 'low' | 'medium' | 'high' | 'full') ?? 'medium',
          (params.fps as number) ?? 24,
          ws,
          undefined,
          undefined,
          undefined,
          { monitor: typeof params.monitor === 'string' ? params.monitor : undefined },
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
      case 'mic.status':
        result = micStatus(ws);
        break;
      case 'mic.start':
        result = startMic(ws, params);
        break;
      case 'mic.stop':
        result = stopMic(ws);
        break;
      case 'screen.setQuality':
        setStreamQuality(
          params.streamId as string,
          params.quality as 'low' | 'medium' | 'high' | 'full',
        );
        result = undefined;
        break;
      case 'screen.reportStats':
        reportStreamStats(
          params.streamId as string,
          params.fps as number,
          params.frameAgeMs as number,
        );
        result = undefined;
        break;
      case 'session.pair':
      case 'session.authenticate':
        throw new WorkspaceError('UNAUTHENTICATED', 'This host uses paired devices. Update NexusLink and enter the code from bun run host:pair.');
      case 'session.heartbeat':
        result = undefined;
        break;
      case 'session.disconnect': {
        const sessionId = findSession(ws);
        if (sessionId) sessions.delete(sessionId);
        result = undefined;
        break;
      }
      case 'push.registerToken':
        result = registerPushToken({
          token: params.token as string,
          provider: params.provider as any,
          endpoint: params.endpoint as string | undefined,
          name: params.name as string | undefined,
        });
        break;
      case 'push.listTokens':
        result = listPushTokens();
        break;
      case 'push.removeToken':
        result = removePushToken(params.token as string);
        break;
      case 'approvals.list':
        result = { items: approvals.list() };
        break;
      case 'approvals.resolve':
        result = approvals.resolve(stringParam(params, 'id'), params.decision === 'allow' ? 'allow' : 'deny',
          params.answers && typeof params.answers === 'object' ? params.answers as Record<string, string> : undefined,
          typeof params.message === 'string' ? params.message : undefined);
        break;
      case 'approvals.status':
        result = approvals.status();
        break;
      case 'approvals.configure':
        result = approvals.configure({
          claude: typeof params.claude === 'boolean' ? params.claude : undefined,
          holdTerminal: typeof params.holdTerminal === 'boolean' ? params.holdTerminal : undefined,
        });
        break;
      case 'push.sendTest':
        result = await sendTestPush({
          title: params.title as string | undefined,
          body: params.body as string | undefined,
        });
        break;
      default:
        throw new WorkspaceError('UNSUPPORTED', `Unsupported RPC method: ${method}`);
    }
    if (['agent.createSession','agent.prompt','agent.renameSession','agent.setSessionCwd','agent.permission','agent.cancel','agent.close'].includes(method)) await flushAgents();
    const response: RpcResponse = { id: req.id, result };
    send(ws, { type: 'rpc-response', response });
  }

  const server = Bun.serve({
    hostname: bindHost,
    port,
    async fetch(req, srv) {
      const url = new URL(req.url);
      const address = (srv as any).requestIP?.(req)?.address as string | undefined;
      if (bindHost === '0.0.0.0' && !isPrivatePeer(address)) {
        return new Response('Use Tailscale or a TLS reverse proxy for remote access.', { status: 403 });
      }
      if (url.pathname === '/files') {
        if (req.method === 'GET' || req.method === 'HEAD') return handleFileDownload(url, req);
        if (req.method === 'POST' || req.method === 'PUT') return handleFileUpload(url, req);
        return new Response('Method not allowed', { status: 405 });
      }
      if (url.pathname === '/signal' || url.pathname === '/rpc') {
        const isLocal = ['127.0.0.1','::1','::ffff:127.0.0.1'].includes(address);
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
        sessions.set(id, { ws: ws as unknown as WebSocket, isLocal, address, authenticated: devBypass });
      },
      async message(ws, raw) {
        if (typeof raw !== 'string') {
          handleMicFrame(ws as unknown as WebSocket, raw as unknown as Uint8Array);
          return;
        }
        let msg: WsMessage;
        try {
          msg = JSON.parse(raw as unknown as string) as WsMessage;
        } catch {
          return;
        }
        if (msg.type === 'rpc-request') {
          try {
            await dispatch(msg.request.method, (msg.request.params as Params) ?? {}, msg.request, ws as unknown as WebSocket);
          } catch (err) {
            if (err instanceof WorkspaceError) console.warn(`[rpc] ${err.code}: ${err.message}`);
            else console.error(`[rpc] ${msg.request.method} failed:`, err instanceof Error ? `${err.name}: ${err.message}` : 'unknown error');
            const response: RpcResponse = { id: msg.request.id, error: err instanceof Error ? err.message : 'Request failed', code: (err as any)?.code || 'INTERNAL' };
            send(ws as unknown as WebSocket, { type: 'rpc-response', response });
          }
        }
      },
      close(ws) {
        chats.subscribe(ws, false);
        detachTerminalsForSocket(ws as unknown as WebSocket);
        stopCapturesForSocket(ws as unknown as WebSocket);
        stopWebrtcForSocket(ws as unknown as WebSocket);
        stopMicForSocket(ws as unknown as WebSocket);
        sessions.forEach((s, id) => {
          if (s.ws === (ws as unknown as WebSocket)) sessions.delete(id);
        });
      },
    },
  });

  const metricTimer = setInterval(async () => {
    const now = Date.now();
    const targets = [...sessions.values()].filter(s => s.topics?.has('metrics') && accessToken(s.token) && now-(s.lastMetric || 0)>=(s.metricsInterval || 5000));
    if (!targets.length) return;
    try { const data = await getPerfSnapshot(); for(const s of targets) { s.lastMetric=now; send(s.ws,{type:'perf-update',data}); } } catch(e) { console.error('Metrics unavailable'); }
  },1000);
  metricTimer.unref();
  const windowTimer = setInterval(async () => {
    const targets=[...sessions.values()].filter(s=>s.topics?.has('windows') && accessToken(s.token));
    if(!targets.length) return;
    try { const windows=await listWindows(); for(const s of targets) send(s.ws,{type:'windows-update',windows}); } catch {}
  },5000);
  windowTimer.unref();
  const monitorTimer = setInterval(() => {
    const now = Date.now();
    const targets = [...sessions.values()].filter(s => s.topics?.has('monitor') && accessToken(s.token) && now - (s.lastMonitor || 0) >= (s.monitorInterval || 2000) - 50);
    if (!targets.length) return;
    try { const snapshot = monitorSnapshot(); for (const s of targets) { s.lastMonitor = now; send(s.ws, { type: 'monitor-update', snapshot }); } } catch (e) { console.error('[monitor] snapshot failed:', e instanceof Error ? e.message : e); }
  }, 500);
  monitorTimer.unref();
  const stopWatchdog = startRemoteWatchdog();
  if (!tailscaleOnly && bindHost === '0.0.0.0') {
    startMdns(port);
  }

  const servesClient = await staticAvailable();
  printLaunchBanner(server.port, servesClient);
  console.log(`[rpc-server] listening on ${bindHost}:${server.port}`);
  return { port: server.port, stop: async () => { setChatLibraryReady(false); await chats.close(); await closeAgentStore(); clearInterval(metricTimer); clearInterval(windowTimer); clearInterval(monitorTimer); approvals.stop(); stopWatchdog(); stopAllTerminals(); unloadMicDevice(); server.stop(true); closeSecurityStore(); } };
}

// Start the server if this file is run directly
if (import.meta.main) {
  // Exit for real on startup failure: background intervals would otherwise keep a dead
  // host alive with no listener, and systemd would never restart it.
  startRpcServer(45678).catch(error => { console.error(error.message); process.exit(1); });
}
