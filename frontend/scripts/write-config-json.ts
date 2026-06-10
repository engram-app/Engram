// frontend/scripts/write-config-json.ts
// Writes dist/config.json from VITE_*-style env vars at build time.
// Used by `bun run build:saas`. Selfhost build does NOT call this.
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const target = process.argv[2] ?? 'dist/config.json'

const config = {
  authProvider: process.env.VITE_AUTH_PROVIDER ?? 'clerk',
  clerkPublishableKey: process.env.VITE_CLERK_PUBLISHABLE_KEY ?? '',
  billingEnabled: process.env.VITE_BILLING_ENABLED === 'true',
  clerkWaitlistMode: process.env.VITE_CLERK_WAITLIST_MODE === 'true',
  apiBase: process.env.VITE_API_BASE ?? '',
  wsBase: process.env.VITE_WS_BASE ?? '',
}

if (!config.clerkPublishableKey) {
  console.error('[write-config-json] VITE_CLERK_PUBLISHABLE_KEY required for saas build')
  process.exit(1)
}

if (!config.apiBase || !config.wsBase) {
  console.error('[write-config-json] VITE_API_BASE and VITE_WS_BASE required for saas build')
  process.exit(1)
}

mkdirSync(dirname(target), { recursive: true })
writeFileSync(target, JSON.stringify(config, null, 2))
console.log(`[write-config-json] wrote ${target}`)
