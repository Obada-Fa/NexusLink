'use client';

import { useEffect, useRef } from 'react';
import { useConnectionStore } from '@/store/connection';
import { deriveHostWsUrl } from '@/lib/host-url';

const STORAGE_KEY = 'nexuslink-host-url';

export default function ConnectionProvider({ children }: { children: React.ReactNode }) {
  const connect = useConnectionStore((s) => s.connect);
  const status = useConnectionStore((s) => s.status);
  const tried = useRef(false);

  useEffect(() => {
    if (tried.current) return;
    tried.current = true;

    // Zero-config: prefer a previously-used host, otherwise auto-derive the host
    // from the page origin (the host served us this page) and connect immediately.
    const target = localStorage.getItem(STORAGE_KEY) || deriveHostWsUrl();
    if (target) {
      connect(target).catch(() => {
        /* silent fail — falls back to the manual connect form */
      });
    }
  }, [connect]);

  useEffect(() => {
    const hostUrl = useConnectionStore.getState().hostUrl;
    if (status === 'connected' && hostUrl) {
      localStorage.setItem(STORAGE_KEY, hostUrl);
    }
  }, [status]);

  return <>{children}</>;
}

export { STORAGE_KEY };
