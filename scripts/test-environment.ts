// Test runs must never load personal history, approval policy or push destinations.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const directory=mkdtempSync(join(tmpdir(),'nexuslink-test-'));
process.env.NEXUSLINK_DATA_DIR=directory;
process.env.NEXUSLINK_LEGACY_AGENT_STORE=join(directory,'legacy-agent-sessions.json');
process.env.NEXUSLINK_DISABLE_PUSH='1';
process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY='1';
process.env.NEXUSLINK_DISABLE_WATCHDOG='1';
process.on('exit',()=>rmSync(directory,{recursive:true,force:true}));
