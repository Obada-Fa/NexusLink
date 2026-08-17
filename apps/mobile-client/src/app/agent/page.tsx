'use client';

import dynamic from 'next/dynamic';
import ConnectionProvider from '@/components/ConnectionProvider';

const AgentContent = dynamic(() => import('./agent-content'), {
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
      Loading agents...
    </div>
  ),
});

export default function AgentPage() {
  return (
    <ConnectionProvider>
      <AgentContent />
    </ConnectionProvider>
  );
}
