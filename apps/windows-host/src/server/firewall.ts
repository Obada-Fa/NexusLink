import { spawnSync } from 'node:child_process';

const RULE = 'NexusLink';

function ruleExists(): boolean {
  const out = spawnSync('netsh', ['advfirewall', 'firewall', 'show', 'rule', `name=${RULE}`], {
    encoding: 'utf-8',
    windowsHide: true,
  });
  return (out.stdout || '').includes(RULE);
}

export function ensureFirewallRule(port = 45678): void {
  if (process.env.NEXUSLINK_NO_FIREWALL === '1') return;
  try {
    if (ruleExists()) return;
    const tcp = spawnSync('netsh', [
      'advfirewall', 'firewall', 'add', 'rule',
      `name=${RULE}`, 'dir=in', 'action=allow', 'protocol=TCP', `localport=${port}`,
    ], { encoding: 'utf-8', windowsHide: true });
    spawnSync('netsh', [
      'advfirewall', 'firewall', 'add', 'rule',
      `name=${RULE} mDNS`, 'dir=in', 'action=allow', 'protocol=UDP', 'localport=5353',
    ], { encoding: 'utf-8', windowsHide: true });
    if (tcp.status !== 0) {
      console.log(`[firewall] inbound TCP ${port} is not open. Run as Administrator or:`);
      console.log(`    netsh advfirewall firewall add rule name=${RULE} dir=in action=allow protocol=TCP localport=${port}`);
    } else {
      console.log(`[firewall] allowed inbound TCP ${port}`);
    }
  } catch (err) {
    console.warn('[firewall]', err);
  }
}
