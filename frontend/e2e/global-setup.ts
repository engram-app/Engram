import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { clerkSetup } from '@clerk/testing/playwright'
import { cleanupTestUsers } from './db-cleanup'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')
const CLERK_API = 'https://api.clerk.com/v1'

export default async function globalSetup() {
  // Clean up stale test users from previous runs (in case teardown didn't run)
  await cleanupTestUsers('setup')

  const secretKey = process.env.E2E_CLERK_SECRET_KEY
  if (!secretKey) {
    console.log('E2E_CLERK_SECRET_KEY not set — Clerk browser tests will be skipped')
    fs.writeFileSync(AUTH_STATE_PATH, JSON.stringify({ skipped: true }))
    return
  }

  // Set CLERK_SECRET_KEY for @clerk/testing (it reads this env var)
  process.env.CLERK_SECRET_KEY = secretKey
  await clerkSetup()

  // Clean up orphaned Clerk users from previous failed runs
  await cleanupOrphanedClerkUsers(secretKey)

  const ts = Date.now()
  const email = `e2e-browser-${ts}@test.com`
  const password = crypto.randomBytes(12).toString('base64url')

  const resp = await fetch(`${CLERK_API}/users`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email_address: [email],
      username: `e2e-browser-${ts}`,
      password,
      skip_password_checks: true,
    }),
  })

  if (!resp.ok) {
    const body = await resp.text()
    throw new Error(`Clerk user creation failed: ${resp.status} ${body}`)
  }

  const user = await resp.json()
  console.log(`Clerk test user created: ${email} (${user.id})`)

  // Block until Clerk's sign-in-tokens endpoint can see this user.
  // Without this, the first test calling clerk.signIn() races Clerk's
  // propagation lag (issue #193). Concentrates the wait into one site
  // so test code doesn't need retries.
  await waitUntilSignInReady(user.id, secretKey)

  fs.writeFileSync(
    AUTH_STATE_PATH,
    JSON.stringify({
      email,
      password,
      clerk_user_id: user.id,
      skipped: false,
    }),
  )
}

const SIGN_IN_READY_MAX_WAIT_MS = 60_000
const SIGN_IN_READY_INITIAL_BACKOFF_MS = 500
const SIGN_IN_READY_MAX_BACKOFF_MS = 8_000

/**
 * Block until Clerk's POST /sign_in_tokens stops 404'ing the given user.
 *
 * Same eventual-consistency story as the Python helper's _wait_until_session_ready
 * (POST /sessions), but for the endpoint @clerk/testing's clerk.signIn uses
 * under the hood. Both endpoints share Clerk's user-lookup propagation lag;
 * probing each one separately means we don't assume they're backed by the
 * same read replica.
 *
 * Throws on non-404 errors or when the wall-clock budget is exhausted.
 */
async function waitUntilSignInReady(userId: string, secretKey: string): Promise<void> {
  const headers = {
    Authorization: `Bearer ${secretKey}`,
    'Content-Type': 'application/json',
  }
  const deadline = Date.now() + SIGN_IN_READY_MAX_WAIT_MS
  let backoff = SIGN_IN_READY_INITIAL_BACKOFF_MS
  let attempt = 0
  // ±20% jitter avoids thundering-herd on Clerk when multiple e2e jobs
  // provision users in parallel during a degraded window.
  const jittered = (ms: number) => ms + ms * (Math.random() * 0.4 - 0.2)

  while (true) {
    attempt++
    const resp = await fetch(`${CLERK_API}/sign_in_tokens`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ user_id: userId, expires_in_seconds: 60 }),
    })
    if (resp.ok) {
      console.log(`Clerk sign-in-tokens probe succeeded for ${userId} on attempt ${attempt} (token discarded)`)
      return
    }
    const body = await resp.text()
    let is404NotFound = false
    if (resp.status === 404) {
      try {
        const parsed = JSON.parse(body) as { errors?: Array<{ code?: string }> }
        is404NotFound = (parsed.errors ?? []).some((e) => e.code === 'resource_not_found')
      } catch {
        // Non-JSON 404 — fall through to the non-propagation error path.
      }
    }
    if (!is404NotFound) {
      throw new Error(`Clerk sign-in-tokens probe failed (non-404 or non-propagation): ${resp.status} ${body}`)
    }
    const remaining = deadline - Date.now()
    if (remaining <= 0) {
      throw new Error(
        `Clerk POST /sign_in_tokens still 404 for user ${userId} after ${SIGN_IN_READY_MAX_WAIT_MS}ms (${attempt} attempts)`,
      )
    }
    const sleepFor = Math.min(jittered(backoff), remaining)
    console.warn(
      `Clerk sign-in-tokens probe 404 for ${userId} (attempt ${attempt}, sleeping ${Math.round(sleepFor)}ms, ${remaining}ms remaining)`,
    )
    await new Promise((r) => setTimeout(r, sleepFor))
    backoff = Math.min(backoff * 2, SIGN_IN_READY_MAX_BACKOFF_MS)
  }
}

// Only clean up browser-e2e's own users — other prefixes belong to the
// Python E2E job which may be running in parallel on the same Clerk account.
const E2E_PREFIXES = ['e2e-browser-']

async function cleanupOrphanedClerkUsers(secretKey: string) {
  const headers = { Authorization: `Bearer ${secretKey}` }
  let deleted = 0

  for (let offset = 0; ; offset += 100) {
    const resp = await fetch(`${CLERK_API}/users?limit=100&offset=${offset}&order_by=created_at`, { headers })
    if (!resp.ok) break
    const users = await resp.json()
    if (!users.length) break

    for (const user of users) {
      const emails: string[] = user.email_addresses?.map((ea: { email_address: string }) => ea.email_address) ?? []
      if (emails.some((e: string) => E2E_PREFIXES.some((p) => e.startsWith(p)))) {
        const del = await fetch(`${CLERK_API}/users/${user.id}`, { method: 'DELETE', headers })
        if (del.ok) deleted++
      }
    }
    if (users.length < 100) break
  }

  if (deleted) console.log(`Cleaned up ${deleted} orphaned Clerk test user(s)`)
}
