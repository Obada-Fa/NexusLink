// Tiered app registry (plan: apps.json). Built-in NexusLink apps declare which
// tier they use: 1 = virtual display, 3 = native web/PTY UI, 4 = agent chat.
// Desktop .desktop entries remain the catalog for "any GUI app" Tier-1 launches.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export type AppTier = 1 | 2 | 3 | 4;
export type AppKind = 'chromium-mobile' | 'code-server' | 'pty' | 'agent' | 'desktop';

export interface RegistryApp {
  appId: string;
  name: string;
  tier: AppTier;
  kind: AppKind;
  iconName?: string;
}

const REGISTRY_PATH = join(dirname(fileURLToPath(import.meta.url)), 'apps.json');

let cache: RegistryApp[] | null = null;

export function listRegistryApps(): RegistryApp[] {
  if (cache) return cache;
  try {
    const raw = JSON.parse(readFileSync(REGISTRY_PATH, 'utf8')) as { apps?: RegistryApp[] };
    cache = Array.isArray(raw.apps) ? raw.apps : [];
  } catch {
    cache = [];
  }
  return cache;
}

export function getRegistryApp(appId: string): RegistryApp | undefined {
  return listRegistryApps().find((a) => a.appId === appId);
}
