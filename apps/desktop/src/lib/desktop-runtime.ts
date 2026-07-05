const HOST_URL_KEY = 'nexuslink-host-url';

export function getHostUrl(): string | null {
  try {
    return localStorage.getItem(HOST_URL_KEY);
  } catch {
    return null;
  }
}

export function setHostUrl(url: string): void {
  try {
    localStorage.setItem(HOST_URL_KEY, url);
  } catch {
    // storage unavailable
  }
}

export function clearHostUrl(): void {
  try {
    localStorage.removeItem(HOST_URL_KEY);
  } catch {
    // storage unavailable
  }
}

export function isDesktop(): boolean {
  try {
    return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
  } catch {
    return false;
  }
}

export async function openExternal(url: string): Promise<void> {
  try {
    const { open } = await import('@tauri-apps/plugin-shell');
    await open(url);
  } catch {
    window.open(url, '_blank', 'noopener,noreferrer');
  }
}

export function relaunch(): void {
  window.location.reload();
}
