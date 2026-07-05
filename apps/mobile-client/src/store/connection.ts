import { create } from 'zustand';
import { RpcClient } from '@/lib/rpc-client';

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected';

export interface ConnectionState {
  status: ConnectionStatus;
  hostUrl: string;
  client: RpcClient | null;
  connect: (hostUrl: string) => Promise<void>;
  disconnect: () => void;
  setHostUrl: (url: string) => void;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  status: 'disconnected',
  hostUrl: '',
  client: null,

  connect: async (hostUrl: string) => {
    const { disconnect: prevDisconnect } = get();
    prevDisconnect();

    const client = new RpcClient(hostUrl);
    set({ status: 'connecting', hostUrl, client });

    try {
      await client.connect();
      set({ status: 'connected' });
    } catch (err) {
      set({ status: 'disconnected' });
      throw err;
    }
  },

  disconnect: () => {
    const { client } = get();
    client?.disconnect();
    set({ status: 'disconnected', client: null });
  },

  setHostUrl: (url: string) => {
    set({ hostUrl: url });
  },
}));
