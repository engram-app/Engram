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
}

function testEmail(label: string) {
  return `e2e-mobile-${Date.now()}-${label}@test.com`
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/sign-in/')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
  await page.getByRole('button', { name: /sign in/i }).click()
  await expect(page).toHaveURL('/')
}

test.describe('Mobile layout', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('header shows hamburger; tapping opens files drawer', async ({ page, baseURL }) => {
    const email = testEmail('files')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    const filesTrigger = page.getByRole('button', { name: 'Open files' })
    await expect(filesTrigger).toBeVisible()
    await filesTrigger.click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Files' })).toBeVisible()
  })

  test('desktop resize handles are not rendered on mobile', async ({ page, baseURL }) => {
    const email = testEmail('handles')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    await expect(page.locator('[data-panel-resize-handle-id]')).toHaveCount(0)
  })

  test('drawers start closed on every navigation', async ({ page, baseURL }) => {
    const email = testEmail('reset')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    await page.getByRole('button', { name: 'Open files' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await page.goto('/settings')
    await expect(page.getByRole('dialog')).toHaveCount(0)
  })
})
