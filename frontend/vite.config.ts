import dns from 'node:dns'
import net from 'node:net'
import https from 'node:https'
import { fileURLToPath } from 'node:url'

// This host has no IPv6 route; staging's DNS returns AAAA records, so the
// proxy's happy-eyeballs races a dead IPv6 connect and 502s. Prefer IPv4 and
// disable family auto-selection so connects use the first (IPv4) address only.
dns.setDefaultResultOrder('ipv4first')
net.setDefaultAutoSelectFamily?.(false)
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
/// <reference types="vitest" />

const apiTarget = process.env.VITE_API_TARGET ?? 'http://localhost:4000'

// Pin the proxy to IPv4. When VITE_API_TARGET is a remote origin whose DNS
// returns AAAA records (e.g. staging behind Cloudflare), Node's happy-eyeballs
// races an IPv6 connect that fails on hosts without IPv6 routing, surfacing as
// a 502 ECONNREFUSED. Only relevant for https targets.
const proxyAgent = apiTarget.startsWith('https') ? new https.Agent({ family: 4 }) : undefined

export default defineConfig({
  test: {
    environment: 'happy-dom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    exclude: ['**/node_modules/**', '**/dist/**', '**/e2e/**'],
  },
  // Tailwind v4 loads the typography plugin via `@plugin` in main.css —
  // the vite plugin's `plugins` option is ignored in this version.
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  base: '/',
  build: {
    outDir: '../priv/static/app',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      // changeOrigin rewrites the Host header to the target — required when
      // VITE_API_TARGET is a remote, host-routed origin (e.g. staging behind
      // Cloudflare); harmless for the localhost default.
      '/api': { target: apiTarget, changeOrigin: true, secure: true, agent: proxyAgent },
      '/socket': {
        target: apiTarget,
        changeOrigin: true,
        secure: true,
        ws: true,
        agent: proxyAgent,
      },
    },
  },
})
