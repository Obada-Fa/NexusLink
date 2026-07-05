'use client';

import { useEffect, useRef } from 'react';
import { useConnectionStore } from '@/store/connection';

const STORAGE_KEY = 'nexuslink-host-url';

export default function ConnectionProvider({ children }: { children: React.ReactNode }) {
  const connect = useConnectionStore((s) => s.connect);
  const status = useConnectionStore((s) => s.status);
  const tried = useRef(false);

  useEffect(() => {
    if (tried.current) return;
    tried.current = true;

    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) {
      connect(saved).catch(() => {
        /* silent fail — user connects manually */
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
