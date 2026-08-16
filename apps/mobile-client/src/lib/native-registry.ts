/**
 * Native-vs-stream routing for the mobile PWA.
 *
 * Registered native tools open RPC-backed pages (no screen capture).
 * Everything else (installed apps / open windows) goes through /mirror
 * (adopt + pixel stream).
 */

export type NativeRouteKind = 'nativeRpc' | 'desktopMirror';

export interface NativeToolEntry {
  id: string;
  label: string;
  icon: string;
  /** Path for Next.js navigation. */
  href: string;
  kind: NativeRouteKind;
}

export const NATIVE_TOOLS: readonly NativeToolEntry[] = [
  { id: 'mirror', label: 'Desktop', icon: '\u{1F5A5}', href: '/mirror', kind: 'desktopMirror' },
  { id: 'terminal', label: 'Terminal', icon: '>_', href: '/terminal', kind: 'nativeRpc' },
  { id: 'files', label: 'Files', icon: '\u{1F4C1}', href: '/files', kind: 'nativeRpc' },
  { id: 'processes', label: 'Tasks', icon: '⚙', href: '/processes', kind: 'nativeRpc' },
  { id: 'system', label: 'System', icon: '\u{1F4CA}', href: '/system', kind: 'nativeRpc' },
] as const;

export function isRegisteredNativeTool(id: string): boolean {
  return NATIVE_TOOLS.some((t) => t.id === id && t.kind === 'nativeRpc');
}
