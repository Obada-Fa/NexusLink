import withPWA from 'next-pwa';

const isDev = process.env.NODE_ENV === 'development';

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Static export so the host's Bun server can serve the PWA on the same port as
  // the RPC WebSocket — one origin, one port, one QR code.
  output: 'export',
  images: { unoptimized: true },
};

const pwaConfig = withPWA({
  dest: 'public',
  disable: isDev,
  runtimeCaching: [
    {
      urlPattern: /^https?:\/\/.*/i,
      handler: 'NetworkFirst',
      options: {
        cacheName: 'nexuslink-cache',
        expiration: { maxEntries: 200, maxAgeSeconds: 60 * 60 * 24 * 7 },
      },
    },
  ],
});

export default pwaConfig(nextConfig);
