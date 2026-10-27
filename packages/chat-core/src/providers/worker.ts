// One long-lived provider worker per ChatService. It never spawns agent CLIs or
// app-servers, so nothing it does writes into the folders the service watches.
import { setRoots } from '../paths';
import { setDiscoveryLimit, takeReadIssue } from './local';
import { Scanner } from './scan';

setDiscoveryLimit(Number.MAX_SAFE_INTEGER);
let scanner = new Scanner();

self.onmessage = (event: MessageEvent) => {
  const { id, op, source, nativeId, ids, fingerprint, roots, cursorBin } = event.data || {};
  try {
    let result: any;
    let reason: string | undefined;
    let extra: Record<string, unknown> = {};
    if (typeof cursorBin === 'boolean') scanner.setCursorBin(cursorBin);
    switch (op) {
      case 'init': setRoots(roots); scanner = new Scanner(); scanner.setCursorBin(!!cursorBin); result = true; break;
      case 'scan': {
        const scan = scanner.scan(source);
        result = scan.result; reason = scan.reason; extra = { complete: scan.complete && !scan.reason };
        break;
      }
      case 'live': result = scanner.live(source, Array.isArray(ids) ? ids : []); break;
      case 'history': {
        const history = scanner.history(source, nativeId, fingerprint);
        result = history.result; reason = history.reason; extra = { fingerprint: history.fingerprint, unchanged: history.unchanged === true };
        if (!history.unchanged && !result.length) reason = 'This app’s history format could not be read, or no messages are available yet.';
        break;
      }
      default: throw new Error('Unknown provider request');
    }
    // Only real failures (unreadable folders, broken stores) are reported; cut-off lines are not.
    takeReadIssue();
    self.postMessage({ id, result, reason, ...extra });
  } catch (error) {
    self.postMessage({ id, error: error instanceof Error && op === 'history' ? error.message : `Couldn’t ${op === 'history' ? 'read' : 'refresh'} ${source}. Check the app and its files on the PC, then retry.` });
  }
};
