import { create } from 'zustand';
import { RpcClient } from '@/lib/rpc-client';
import { performPairingHandshake } from '@/lib/auth-client';

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected';

export interface ConnectionState {
  status: ConnectionStatus;
  hostUrl: string;
  client: RpcClient | null;
  authenticated: boolean;
  connect: (hostUrl: string) => Promise<void>;
  disconnect: () => void;
  setHostUrl: (url: string) => void;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  status: 'disconnected',
  hostUrl: '',
  client: null,
  authenticated: false,

  connect: async (hostUrl: string) => {
    const { disconnect: prevDisconnect } = get();
    prevDisconnect();

    const client = new RpcClient(hostUrl);
    set({ status: 'connecting', hostUrl, client, authenticated: false });

    try {
      await client.connect();

      // Perform ECDH + TOTP pairing handshake to authenticate this session.
      await performPairingHandshake(
        hostUrl,
        async (params) => client.request('session.pair', params) as Promise<{ publicKey: string; totpIssuerUri: string }>,
        async (params) => client.request('session.authenticate', params) as Promise<{ token: string }>,
      );

      set({ status: 'connected', authenticated: true });
    } catch (err) {
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
