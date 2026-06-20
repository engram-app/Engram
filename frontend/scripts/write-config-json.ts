// frontend/scripts/write-config-json.ts
// Writes dist/config.json from VITE_*-style env vars at build time.
// Used by `bun run build:saas`. Selfhost build does NOT call this.
//
// This file is the FALLBACK config source: the saas build also inlines the
// same config into index.html as window.__ENGRAM_CONFIG__ (see the
// engram-inline-bootstrap plugin in vite.config.ts), so the SPA normally
// resolves config synchronously and never fetches this. Kept as a belt-and-
// suspenders fallback and for use-bootstrap.ts.
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { bootstrapConfigFromEnv } from './bootstrap-config'

const target = process.argv[2] ?? 'dist/config.json'

const { config, errors } = bootstrapConfigFromEnv(process.env)

if (errors.length > 0) {
  for (const err of errors) console.error(`[write-config-json] ${err}`)
  process.exit(1)
}

mkdirSync(dirname(target), { recursive: true })
writeFileSync(target, JSON.stringify(config, null, 2))
console.log(`[write-config-json] wrote ${target}`)
