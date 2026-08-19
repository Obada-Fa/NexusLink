import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const tauriConfigPath = resolve('apps/desktop/src-tauri/tauri.conf.json');

const WINDOWS_TARGETS = new Set([
  'msi',
  'nsis',
  'wix',
  'appx',
]);

const LINUX_TARGETS = new Set([
  'deb',
  'rpm',
  'appimage',
]);

function fail(message) {
  console.error(`[guard] ${message}`);
  process.exit(1);
}

let raw;
try {
  raw = readFileSync(tauriConfigPath, 'utf8');
} catch (error) {
  fail(`Could not read ${tauriConfigPath}: ${error instanceof Error ? error.message : String(error)}`);
}

let parsed;
try {
  parsed = JSON.parse(raw);
} catch (error) {
  fail(`Invalid JSON in ${tauriConfigPath}: ${error instanceof Error ? error.message : String(error)}`);
}

const targets = parsed?.bundle?.targets;

if (!Array.isArray(targets) || targets.length === 0) {
  fail('apps/desktop must declare bundle.targets as a non-empty array of Linux targets.');
}

const normalized = targets.map((t) => String(t).trim().toLowerCase());
const windows = normalized.filter((t) => WINDOWS_TARGETS.has(t));
const nonLinux = normalized.filter((t) => !LINUX_TARGETS.has(t));

if (windows.length > 0) {
  fail(`Windows bundle targets are not allowed in apps/desktop: ${windows.join(', ')}`);
}

if (nonLinux.length > 0) {
  fail(`Unsupported non-Linux targets in apps/desktop: ${nonLinux.join(', ')}`);
}

console.log(`[guard] OK: Linux-only bundle targets (${normalized.join(', ')})`);
