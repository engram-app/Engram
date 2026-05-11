import { test, expect, type Page } from '@playwright/test'
import { setupClerkTestingToken, clerk } from '@clerk/testing/playwright'
import fs from 'node:fs'
import path from 'node:path'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')

function loadAuthState(): { email: string; password: string; clerk_user_id: string; skipped: boolean } {
  if (!fs.existsSync(AUTH_STATE_PATH)) {
    return { email: '', password: '', clerk_user_id: '', skipped: true }
  }
  return JSON.parse(fs.readFileSync(AUTH_STATE_PATH, 'utf-8'))
}

const SIGN_IN = '[data-clerk-component="SignIn"]'
const SIGN_UP = '[data-clerk-component="SignUp"]'
const USER_BUTTON = '[data-clerk-component="UserButton"]'

/**
 * Sign in via Clerk Backend API ticket — bypasses form + bot detection entirely.
 * Creates a sign-in token server-side, then uses it client-side via strategy: 'ticket'.
 * Requires CLERK_SECRET_KEY env var (set in global-setup).
 */
async function clerkSignIn(page: Page, email: string) {
  // Navigate first so Clerk JS SDK loads on the page
  await page.goto('/sign-in/')
  await clerk.signIn({ page, emailAddress: email })
  await page.goto('/')
  await expect(page).toHaveURL(/\/$/, { timeout: 15_000 })
}

test.describe('Clerk auth provider', () => {
  const state = loadAuthState()

  test.skip(() => state.skipped, 'E2E_CLERK_SECRET_KEY not set — skipping Clerk browser tests')

  // Bypass Clerk's bot detection — intercepts Clerk Frontend API requests
  // and injects testing token + captcha bypass via @clerk/testing
  test.beforeEach(async ({ page }) => {
    await setupClerkTestingToken({ page })
  })

  test('redirects unauthenticated users to sign-in with Clerk UI', async ({ page }) => {
    await page.goto('/')
    // Wait for auth provider to finish loading before checking redirect
    await page.getByText('Loading...').waitFor({ state: 'hidden', timeout: 15_000 })
    await expect(page).toHaveURL(/\/sign-in/)
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })
    await expect(page.locator('h1.cl-headerTitle')).toContainText('Sign in')
  })

  test('renders Clerk SignUp component', async ({ page }) => {
    await page.goto('/sign-up/')
    // Wait for Clerk container to attach, then for SDK to render it visible
    await page.locator(SIGN_UP).waitFor({ state: 'attached', timeout: 15_000 })
    await expect(page.locator(SIGN_UP)).toBeVisible({ timeout: 15_000 })
  })

  test('sign in via Clerk → dashboard', async ({ page }) => {
    await clerkSignIn(page, state.email)
  })

  test('Clerk UserButton renders in header', async ({ page }) => {
    await clerkSignIn(page, state.email)

    await expect(page.locator(USER_BUTTON)).toBeVisible()
  })

  test('sign out via Clerk → redirects', async ({ page }) => {
    await clerkSignIn(page, state.email)

    await page.locator(USER_BUTTON).click()
    await page.getByRole('menuitem', { name: /sign out/i }).click()

    await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })
  })

  test('wrong password shows Clerk error', async ({ page }) => {
    await page.goto('/sign-in/')
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })

    await page.locator('input[name="identifier"]').fill(state.email)
    await page.locator('.cl-formButtonPrimary').click()

    const pwInput = page.locator('input[name="password"]')
    await expect(pwInput).toBeVisible({ timeout: 10_000 })
    await pwInput.fill('WrongPassword!99')
    await page.locator('.cl-formButtonPrimary').click()

    await expect(page.locator('.cl-formFieldErrorText').first()).toBeVisible({ timeout: 10_000 })
    await expect(page).toHaveURL(/\/sign-in/)
  })
})
