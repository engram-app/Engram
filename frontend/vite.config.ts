import { readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Plugin } from 'vite'
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

// Source maps must NEVER ship to the public asset directory — they fully
// de-minify and expose application source. Sentry's plugin deletes them
// after upload, but ONLY when it is active; the Cloudflare Workers saas
// deploy builds with no SENTRY_AUTH_TOKEN, so the plugin self-disables and
// the maps would otherwise be served at app.engram.page. This fallback
// strips every leftover *.map from the build output whenever Sentry is not
// doing the upload (and therefore not deleting them itself).
function stripSourceMaps(outDir: string): Plugin {
  const deleteMaps = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) deleteMaps(full)
      else if (entry.name.endsWith('.map')) rmSync(full)
    }
  }

  return {
    name: 'engram-strip-source-maps',
    apply: 'build',
    closeBundle() {
      try {
        deleteMaps(outDir)
      } catch {
        // outDir may not exist (aborted build) — nothing to strip.
      }
    },
  }
}

const buildOutDir = fileURLToPath(new URL('../priv/static/app', import.meta.url))

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
      // When Sentry IS uploading, have it delete the maps it just uploaded.
      sourcemaps: { filesToDeleteAfterUpload: ['**/*.map'] },
    }),
    // Backstop for builds where Sentry is disabled (no auth token).
    stripSourceMaps(buildOutDir),
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
    // 'hidden' generates maps (so Sentry can de-minify stack traces) but omits
    // the //# sourceMappingURL comment, so browsers never auto-fetch them.
    // The maps themselves are removed from served output after build by the
    // Sentry plugin (on upload) or the stripSourceMaps backstop (otherwise).
    sourcemap: 'hidden',
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
      // OAuth API endpoints — Phoenix-served JSON. /oauth/consent is a SPA
      // route (React renders consent UI) so we DON'T proxy that one.
      '/oauth/register': { target: apiTarget, changeOrigin: true },
      '/oauth/token': { target: apiTarget, changeOrigin: true },
      '/oauth/revoke': { target: apiTarget, changeOrigin: true },
      '/oauth/authorize': { target: apiTarget, changeOrigin: true },
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
