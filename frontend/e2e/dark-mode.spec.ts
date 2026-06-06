import { test, expect } from '@playwright/test'

const TEST_PASSWORD = 'E2eTestPass!99'

async function registerUser(baseURL: string, email: string) {
  const res = await fetch(`${baseURL}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: TEST_PASSWORD }),
  })
  if (res.status === 422) return
  if (!res.ok) throw new Error(`Register failed: ${res.status} ${await res.text()}`)
  const { access_token: token } = await res.json()
  const auth = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }
  const prof = await fetch(`${baseURL}/api/onboarding/profile`, {
    method: 'PATCH',
    headers: auth,
    body: JSON.stringify({ uses_obsidian: true, tools: ['claude'] }),
  })
  if (!prof.ok) throw new Error(`onboarding PATCH failed: ${prof.status} ${await prof.text()}`)
  const act = await fetch(`${baseURL}/api/onboarding/actions`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({ action: 'dismissed:tour' }),
  })
  if (!act.ok) throw new Error(`onboarding action POST failed: ${act.status} ${await act.text()}`)
  const vault = await fetch(`${baseURL}/api/vaults`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({ name: 'E2E Vault' }),
  })
  if (!vault.ok) throw new Error(`vault POST failed: ${vault.status} ${await vault.text()}`)
}

function testEmail(label: string) {
  return `e2e-theme-${Date.now()}-${label}@test.com`
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/sign-in/')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
  await page.getByRole('button', { name: /sign in/i }).click()
  await expect(page).toHaveURL('/')
}

test.describe('Dark mode', () => {
  test('header toggle opens menu and picks each theme', async ({ page, baseURL }) => {
    const email = testEmail('menu')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    const toggle = page.getByRole('button', { name: /^theme:/i })
    await expect(page.locator('html')).not.toHaveClass(/dark/)
    await expect(toggle).toHaveAttribute('data-theme-choice', 'system')

    // Open menu → pick Dark
    await toggle.click()
    const menu = page.getByRole('menu', { name: 'Theme' })
    await expect(menu).toBeVisible()
    await menu.getByRole('menuitem', { name: 'Dark' }).click()
    await expect(menu).toBeHidden()
    await expect(page.locator('html')).toHaveClass(/dark/)
    await expect(toggle).toHaveAttribute('data-theme-choice', 'dark')

    // Open menu → pick Light
    await toggle.click()
    await page.getByRole('menuitem', { name: 'Light' }).click()
    await expect(page.locator('html')).not.toHaveClass(/dark/)
    await expect(toggle).toHaveAttribute('data-theme-choice', 'light')

    // Open menu → pick System; localStorage persists
    await toggle.click()
    await page.getByRole('menuitem', { name: 'System' }).click()
    await expect(toggle).toHaveAttribute('data-theme-choice', 'system')
    const stored = await page.evaluate(() => window.localStorage.getItem('engram:theme'))
    expect(stored).toBe('system')

    // Esc closes the menu without changing theme
    await toggle.click()
    await expect(page.getByRole('menu', { name: 'Theme' })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.getByRole('menu', { name: 'Theme' })).toBeHidden()
    await expect(toggle).toHaveAttribute('data-theme-choice', 'system')
  })

  test('System mode tracks prefers-color-scheme', async ({ browser, baseURL }) => {
    const email = testEmail('system')
    await registerUser(baseURL!, email)

    const ctx = await browser.newContext({ colorScheme: 'dark' })
    const page = await ctx.newPage()
    await signIn(page, email)

    // First-paint check: with empty storage (system) + colorScheme dark, html should have .dark.
    await expect(page.locator('html')).toHaveClass(/dark/)
    await ctx.close()
  })

  test('FOUC-free: pre-seeded localStorage applies class before React mounts', async ({ browser, baseURL }) => {
    const email = testEmail('fouc')
    await registerUser(baseURL!, email)

    const ctx = await browser.newContext()
    await ctx.addInitScript(() => {
      window.localStorage.setItem('engram:theme', 'dark')
    })
    const page = await ctx.newPage()
    await page.goto(baseURL! + '/sign-in/')
    // At domcontentloaded the inline boot script has already run.
    await page.waitForLoadState('domcontentloaded')
    await expect(page.locator('html')).toHaveClass(/dark/)
    await ctx.close()
  })
})
