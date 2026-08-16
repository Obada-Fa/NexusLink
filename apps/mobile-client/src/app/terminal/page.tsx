'use client';

import dynamic from 'next/dynamic';
import ConnectionProvider from '@/components/ConnectionProvider';

const TerminalContent = dynamic(() => import('./terminal-content'), {
  ssr: false,
  loading: () => (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100dvh',
        background: '#0d0d12',
        color: '#555',
        fontFamily: 'system-ui, sans-serif',
        fontSize: '14px',
      }}
    >
      Opening terminal…
    </div>
  ),
});

export default function TerminalPage() {
  return (
    <ConnectionProvider>
      <TerminalContent />
    </ConnectionProvider>
  );
}
