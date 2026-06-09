import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { sentryVitePlugin } from '@sentry/vite-plugin'
/// <reference types="vitest" />

const apiTarget = process.env.VITE_API_TARGET ?? 'http://localhost:4000'

// Sentry source-map upload + release tagging. Active only when
// SENTRY_AUTH_TOKEN is present at build time (i.e. CI on the deploy
// workflow, never local dev). Plugin is a no-op otherwise — set
// `disable: true` so it doesn't try to upload empty assets.
const sentryAuthToken = process.env.SENTRY_AUTH_TOKEN

export default defineConfig({
  test: {
    environment: 'happy-dom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    exclude: ['**/node_modules/**', '**/dist/**', '**/e2e/**'],
  },
  // Tailwind v4 loads the typography plugin via `@plugin` in main.css —
  // the vite plugin's `plugins` option is ignored in this version.
  plugins: [
    react(),
    tailwindcss(),
    sentryVitePlugin({
      org: process.env.SENTRY_ORG ?? 'engram-app',
      project: process.env.SENTRY_PROJECT ?? 'engram-frontend',
      authToken: sentryAuthToken,
      disable: !sentryAuthToken,
      release: { name: process.env.VITE_GIT_SHA },
    }),
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  base: '/',
  build: {
    outDir: '../priv/static/app',
    emptyOutDir: true,
    // Generate sourcemaps so Sentry can deminify production stack
    // traces. Slightly larger bundle (~10-30%); acceptable cost for
    // useful crash reports. The Sentry plugin (configured above)
    // uploads them at build time when SENTRY_AUTH_TOKEN is set.
    sourcemap: true,
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
      '/oauth': {
        target: apiTarget,
        changeOrigin: true,
      },
      '/.well-known': {
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
