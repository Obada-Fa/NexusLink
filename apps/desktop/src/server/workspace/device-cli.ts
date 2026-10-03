import { enableEnrollment, listDevices, revokeDevice } from './security';
const command = process.argv[2] || 'pair';
if (command === 'pair') console.log(`NexusLink pairing code: ${enableEnrollment()}\nExpires in five minutes; can be used once.`);
else if (command === 'list') console.table(listDevices());
else if (command === 'revoke' && process.argv[3]) { revokeDevice(process.argv[3]); console.log('Device revoked.'); }
else { console.error('Usage: device-cli.ts pair | list | revoke <device-id>'); process.exitCode = 1; }
