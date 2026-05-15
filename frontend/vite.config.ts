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
      '/api': apiTarget,
      '/socket': {
        target: apiTarget,
        ws: true,
      },
    },
  },
})
