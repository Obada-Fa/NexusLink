import { create } from 'zustand';
import { RpcClient } from '@/lib/rpc-client';
import { authenticateWorkspace } from '@/lib/auth-client';

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected';

export interface ConnectionState {
  status: ConnectionStatus;
  hostUrl: string;
  client: RpcClient | null;
  authenticated: boolean;
  connect: (hostUrl: string, pairingCode?: string) => Promise<void>;
  disconnect: () => void;
  setHostUrl: (url: string) => void;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  status: 'disconnected',
  hostUrl: '',
  client: null,
  authenticated: false,

  connect: async (hostUrl: string, pairingCode?: string) => {
    const { disconnect: prevDisconnect } = get();
    prevDisconnect();

    const client = new RpcClient(hostUrl, async rpc => {
      const auth=await authenticateWorkspace(hostUrl, (method,params)=>rpc.request(method,params), pairingCode);
      rpc.token=auth.token;pairingCode=undefined;
    }, status=>{if(get().client===client)set({status,authenticated:status==='connected'});});
    set({ status: 'connecting', hostUrl, client, authenticated: false });

    try {
      await client.connect();

      set({ status: 'connected', authenticated: true });
    } catch (err) {
      client.disconnect();
      if(get().client!==client)throw err;
      set({ status: 'disconnected', client: null, authenticated: false });
      throw err;
    }
  },

  disconnect: () => {
    const { client } = get();
    client?.disconnect();
    set({ status: 'disconnected', client: null, authenticated: false });
  },

  setHostUrl: (url: string) => {
    set({ hostUrl: url });
  },
}));
