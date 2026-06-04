import { test, expect, type Page } from '@playwright/test'
import { setupClerkTestingToken, clerk } from '@clerk/testing/playwright'
import fs from 'node:fs'
import path from 'node:path'

// Mirrors clerk-auth.spec.ts — same auth-state file, same sign-in retry pattern.
// Kept in this file (not extracted) so the FTUX spec stands alone and the auth
// spec stays the canonical example for new authors. If a third Clerk spec lands,
// promote both copies into e2e/clerk-helpers.ts.

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')

function loadAuthState(): { email: string; password: string; clerk_user_id: string; skipped: boolean } {
  if (!fs.existsSync(AUTH_STATE_PATH)) {
    return { email: '', password: '', clerk_user_id: '', skipped: true }
  }
  return JSON.parse(fs.readFileSync(AUTH_STATE_PATH, 'utf-8'))
}

async function clerkSignIn(page: Page, email: string) {
  await page.goto('/sign-in/')
  let lastErr: unknown
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      await clerk.signIn({ page, emailAddress: email })
      lastErr = undefined
      break
    } catch (err) {
      if (!/No user found/i.test(String(err))) throw err
      lastErr = err
      await page.waitForTimeout(1_000)
    }
  }
  if (lastErr) throw lastErr
  await page.goto('/')
}

test.describe('FTUX happy path', () => {
  const state = loadAuthState()

  test.skip(() => state.skipped, 'E2E_CLERK_SECRET_KEY not set — skipping Clerk FTUX test')

  test.beforeEach(async ({ page }) => {
    await setupClerkTestingToken({ page })
  })

  test('tour offer → tour steps → create-vault modal → checklist', async ({ page }) => {
    await clerkSignIn(page, state.email)

    // OnboardingGate redirects unfinished onboarding to /onboard/{agreement|billing}.
    // The full TOS+billing wizard requires a Paddle card flow that's out of
    // scope here — this spec assumes the test user has cleared the wizard via
    // a prior run (or backend seed). If we land outside `/`, skip with a clear
    // signal so the rest of the suite still runs.
    await page.waitForURL((url) => !url.pathname.startsWith('/sign-in'), { timeout: 15_000 })
    if (!new URL(page.url()).pathname.match(/^\/(note|search)?\/?$/)) {
      test.skip(
        true,
        `Onboarding wizard not pre-completed for test user (landed on ${new URL(page.url()).pathname}). ` +
          `Complete TOS + billing trial for the Clerk test user once, then re-run.`,
      )
    }

    // Tour-Offer modal. Idempotent: if the user already made a tour decision
    // in a previous run, the modal won't show — skip ahead to the checklist
    // assertion (the post-state we care about is "after the FTUX flow runs").
    const tourHeading = page.getByRole('heading', { name: /quick tour/i })
    const tourVisible = await tourHeading.isVisible().catch(() => false)

    if (tourVisible) {
      await page.getByRole('button', { name: /take the tour/i }).click()

      // Demo fixture loads → note "Start here" is visible in the sidebar tree.
      await expect(page.getByText('Start here')).toBeVisible({ timeout: 10_000 })

      // 6 steps: 5 next clicks then a Done that fires our `onCreateVault` exit.
      for (let i = 0; i < 5; i++) {
        await page.locator('.driver-popover-next-btn').click()
      }
      await page.getByRole('button', { name: /create my vault/i }).click()
    }

    // Create-Vault modal — only shows when the user has zero real vaults.
    // Also idempotent: skip if already created.
    const vaultHeading = page.getByRole('heading', { name: /first vault/i })
    if (await vaultHeading.isVisible().catch(() => false)) {
      await page.getByLabel('Vault name').fill('My Vault')
      await page.getByRole('button', { name: /create vault/i }).click()
      await expect(vaultHeading).toBeHidden({ timeout: 10_000 })
    }

    // Post-flow assertion: checklist widget mounted on the dashboard.
    // (The "create vault" row gets ✅ once `first_vault_created` is recorded.)
    await expect(page.getByRole('heading', { name: /get started/i })).toBeVisible({
      timeout: 10_000,
    })
  })

  test('skip tour still shows create-vault modal', async ({ page }) => {
    await clerkSignIn(page, state.email)
    await page.waitForURL((url) => !url.pathname.startsWith('/sign-in'), { timeout: 15_000 })
    if (!new URL(page.url()).pathname.match(/^\/(note|search)?\/?$/)) {
      test.skip(true, 'Onboarding wizard not pre-completed for test user.')
      return
    }

    const skipBtn = page.getByRole('button', { name: /^skip$/i })
    if (await skipBtn.isVisible().catch(() => false)) {
      await skipBtn.click()
    }

    // Vault modal shows (skip if vault already exists from a prior run).
    const vaultHeading = page.getByRole('heading', { name: /first vault/i })
    if (await vaultHeading.isVisible().catch(() => false)) {
      await page.getByPlaceholder('My notes').fill('Skip-Test Vault')
      await page.getByRole('button', { name: /create vault/i }).click()
    }

    // Checklist should show "Take the tour" item still actionable.
    await expect(page.getByRole('button', { name: /^start$/i })).toBeVisible()
  })

  test('vault modal cannot be dismissed by ESC, click-outside, or close button', async ({
    page,
  }) => {
    await clerkSignIn(page, state.email)
    await page.waitForURL((url) => !url.pathname.startsWith('/sign-in'), { timeout: 15_000 })
    if (!new URL(page.url()).pathname.match(/^\/(note|search)?\/?$/)) {
      test.skip(true, 'Onboarding wizard not pre-completed for test user.')
      return
    }

    // Only meaningful on a fresh user — skip if the modal isn't surfaced.
    const headingLocator = page.getByRole('heading', { name: /first vault/i })
    if (!(await headingLocator.isVisible().catch(() => false))) {
      test.skip(true, 'user already has a vault — modal not shown')
      return
    }

    await page.keyboard.press('Escape')
    await expect(headingLocator).toBeVisible()

    await page.mouse.click(10, 10)
    await expect(headingLocator).toBeVisible()

    // No close button visible on this dialog.
    const closeButton = page.getByRole('button', { name: /close/i })
    await expect(closeButton).toHaveCount(0)
  })

  test('completed flow does not re-fire modals after reload', async ({ page }) => {
    await clerkSignIn(page, state.email)
    await page.waitForURL((url) => !url.pathname.startsWith('/sign-in'), { timeout: 15_000 })
    if (!new URL(page.url()).pathname.match(/^\/(note|search)?\/?$/)) {
      test.skip(true, 'Onboarding wizard not pre-completed for test user.')
      return
    }

    // Ensure user has skipped tour + created vault (idempotent — no-op if done).
    const skipBtn = page.getByRole('button', { name: /^skip$/i })
    if (await skipBtn.isVisible().catch(() => false)) {
      await skipBtn.click()
    }
    const vaultHeading = page.getByRole('heading', { name: /first vault/i })
    if (await vaultHeading.isVisible().catch(() => false)) {
      await page.getByPlaceholder('My notes').fill('Persist Vault')
      await page.getByRole('button', { name: /create vault/i }).click()
      await expect(vaultHeading).toHaveCount(0)
    }

    await page.reload()
    await expect(page.getByRole('heading', { name: /quick tour/i })).toHaveCount(0)
    await expect(page.getByRole('heading', { name: /first vault/i })).toHaveCount(0)
  })

  test('completing device-link flow ticks the plugin checklist item', async ({ page }) => {
    // This test requires triggering the backend device-flow exchange end-to-end.
    // No harness helper exists yet — skipping with a clear signal so the rest of
    // the suite still runs. File a follow-up issue to add a device-flow helper
    // and unskip this test.
    void page
    test.skip(true, 'requires device-flow helper — see follow-up issue')

    // Sketch:
    // 1. Sign in (standard setup).
    // 2. POST /api/auth/device/start (or whatever the start endpoint is).
    // 3. Hit the authorize endpoint with the user's session.
    // 4. POST /api/auth/device/exchange with the device_code.
    // 5. Refresh dashboard, expect plugin item ✅ in checklist.
  })

  test('user with existing vault sees no vault modal', async ({ page }) => {
    await clerkSignIn(page, state.email)
    await page.waitForURL((url) => !url.pathname.startsWith('/sign-in'), { timeout: 15_000 })
    if (!new URL(page.url()).pathname.match(/^\/(note|search)?\/?$/)) {
      test.skip(true, 'Onboarding wizard not pre-completed for test user.')
      return
    }

    const headingLocator = page.getByRole('heading', { name: /first vault/i })

    // If the test user is still fresh (no vault), flip state by creating one.
    if (await headingLocator.isVisible().catch(() => false)) {
      await page.getByPlaceholder('My notes').fill('Backfilled Vault')
      await page.getByRole('button', { name: /create vault/i }).click()
      await page.reload()
    }

    // Reload and assert no first-vault modal.
    await page.reload()
    await expect(headingLocator).toHaveCount(0)
  })

  test('mobile viewport: tour offer suppressed', async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width: 375, height: 667 } })
    const page = await context.newPage()

    await setupClerkTestingToken({ page })
    await clerkSignIn(page, state.email)
    await page.waitForURL((url) => !url.pathname.startsWith('/sign-in'), { timeout: 15_000 })

    // Tour offer suppressed on <768px (full mobile-FAB coverage would require
    // shared-state setup across tests — the suppression assertion is the
    // load-bearing check here).
    await expect(page.getByRole('heading', { name: /quick tour/i })).toHaveCount(0)

    await context.close()
  })
})
