'use client';

import dynamic from 'next/dynamic';

const TerminalContent = dynamic(() => import('./terminal-content'), {
  ssr: false,
  loading: () => (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100dvh',
        background: '#0a0a0f',
        color: '#555',
        fontFamily: 'system-ui, sans-serif',
        fontSize: '14px',
      }}
    >
      Loading terminal...
    </div>
  ),
});

export default function TerminalPage() {
  return <TerminalContent />;
}
