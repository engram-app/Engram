import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
/// <reference types="vitest" />

const apiTarget = process.env.VITE_API_TARGET ?? 'http://localhost:4000'

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
      // VITE_API_TARGET points at a remote host routed by Host (e.g. Cloudflare);
      // harmless against localhost.
      '/api': {
        target: apiTarget,
        changeOrigin: true,
      },
      '/socket': {
        target: apiTarget,
        changeOrigin: true,
        ws: true,
      },
    },
  },
})
