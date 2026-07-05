import withPWA from 'next-pwa';

const isDev = process.env.NODE_ENV === 'development';

/** @type {import('next').NextConfig} */
const nextConfig = {};

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
