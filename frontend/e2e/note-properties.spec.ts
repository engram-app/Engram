import { test, expect, type Page } from '@playwright/test'

/**
 * E2e coverage for the PropertiesWidget (#frontmatter-properties).
 *
 * Two tests:
 *   1. Editing a property value in one tab converges to a second tab via CRDT.
 *   2. A type override stored in Y.Map("frontmatter_types") survives a page reload
 *      (IndexedDB-persisted by y-indexeddb; web-only, not sent to the backend).
 *
 * Helpers are copied from note-live-update.spec.ts — same shape, same API contract.
 */

const PASS = 'E2eTestPass!99'

async function registerAndLogin(baseURL: string, email: string): Promise<string> {
  const reg = await fetch(`${baseURL}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASS }),
  })
  if (!reg.ok && reg.status !== 422) {
    throw new Error(`register failed: ${reg.status} ${await reg.text()}`)
  }

  const login = await fetch(`${baseURL}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASS }),
  })
  if (!login.ok) throw new Error(`login failed: ${login.status} ${await login.text()}`)
  const { access_token } = (await login.json()) as { access_token: string }

  const auth = { 'Content-Type': 'application/json', Authorization: `Bearer ${access_token}` }
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

  return access_token
}

interface Vault {
  id: number
  name: string
}

async function createVault(baseURL: string, token: string, name: string): Promise<Vault> {
  const res = await fetch(`${baseURL}/api/vaults`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ name }),
  })
  if (!res.ok) throw new Error(`vault create failed: ${res.status} ${await res.text()}`)
  const { vault } = (await res.json()) as { vault: Vault }
  return vault
}

async function upsertNote(
  baseURL: string,
  token: string,
  vaultId: number,
  path: string,
  content: string,
  version?: number,
): Promise<{ id: number }> {
  const res = await fetch(`${baseURL}/api/notes`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'X-Vault-Id': String(vaultId),
    },
    body: JSON.stringify({ path, content, mtime: Date.now() / 1000, version }),
  })
  if (!res.ok) throw new Error(`note upsert failed: ${res.status} ${await res.text()}`)
  const { note } = (await res.json()) as { note: { id: number } }
  return { id: note.id }
}

/**
 * Navigate to the note URL; AuthGuard redirects to /sign-in, complete sign-in,
 * and land back on /note/:id. Seeds engram.activeVaultId before sign-in so the
 * post-redirect render uses the correct vault.
 */
async function signInForNote(
  page: Page,
  email: string,
  vaultId: number,
  noteId: number,
): Promise<void> {
  await page.goto(`/note/${noteId}`)
  await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })

  await page.evaluate((id) => {
    localStorage.setItem('engram.activeVaultId', String(id))
  }, vaultId)

  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password', { exact: true }).fill(PASS)
  await page.getByRole('button', { name: /sign in/i }).click()

  await expect(page).toHaveURL(new RegExp(`/note/${noteId}`), { timeout: 10_000 })
}

/**
 * Wait for the PropertiesWidget to show the given key (the <dt> text) so we
 * know the CRDT frontmatter maps have been seeded from the backend.
 */
async function waitForProperty(page: Page, key: string): Promise<void> {
  await expect(page.getByRole('term').filter({ hasText: key })).toBeVisible({ timeout: 10_000 })
}

test.describe('PropertiesWidget e2e', () => {
  test('editing a property in one tab converges in another (CRDT)', async ({
    browser,
    baseURL,
  }) => {
    const email = `e2e-props-crdt-${Date.now()}@test.com`
    const token = await registerAndLogin(baseURL!, email)
    const vault = await createVault(baseURL!, token, `props-crdt-${Date.now()}`)
    const path = 'props-crdt.md'
    // Upsert a note with YAML frontmatter so the backend seeds the
    // Y.Map("frontmatter") during the CRDT STEP1/STEP2 handshake.
    const { id: noteId } = await upsertNote(
      baseURL!,
      token,
      vault.id,
      path,
      '---\ntitle: Hello\n---\n\nBody text.',
    )

    const ctxA = await browser.newContext()
    const pageA = await ctxA.newPage()
    const ctxB = await browser.newContext()
    const pageB = await ctxB.newPage()

    await signInForNote(pageA, email, vault.id, noteId)
    await signInForNote(pageB, email, vault.id, noteId)

    // Wait for the PropertiesWidget to show "title" in both tabs.
    await waitForProperty(pageA, 'title')
    await waitForProperty(pageB, 'title')

    // In tab A: click into the "title" value field (the input in the title row's <dd>)
    // and change the value, then blur to commit.
    const rowA = pageA.getByTestId('property-row-title')
    const valueInputA = rowA.locator('dd input')
    await valueInputA.fill('Hello CRDT')
    await valueInputA.blur()

    // In tab B: the PropertiesWidget observes Y.Map changes and re-renders.
    // Assert the value field reflects the new value within the CRDT propagation window.
    // If this assertion times out it is a real CRDT convergence bug — do NOT weaken it.
    const rowB = pageB.getByTestId('property-row-title')
    const valueInputB = rowB.locator('dd input')
    await expect(valueInputB).toHaveValue('Hello CRDT', { timeout: 10_000 })

    await ctxA.close()
    await ctxB.close()
  })

  test('a type override persists across reload', async ({ browser, baseURL }) => {
    const email = `e2e-props-type-${Date.now()}@test.com`
    const token = await registerAndLogin(baseURL!, email)
    const vault = await createVault(baseURL!, token, `props-type-${Date.now()}`)
    const path = 'props-type.md'
    // Note with a "due" text property (value is plain text, so inferred type = "text").
    const { id: noteId } = await upsertNote(
      baseURL!,
      token,
      vault.id,
      path,
      '---\ndue: some text\n---\n\nBody text.',
    )

    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await signInForNote(page, email, vault.id, noteId)

    // Wait for the PropertiesWidget to render the "due" property.
    await waitForProperty(page, 'due')

    // Verify the initial inferred type is "text" (the trigger label shows the current type).
    const row = page.getByTestId('property-row-due')
    const typeButton = row.getByRole('button', { name: 'Property type' })
    await expect(typeButton).toHaveText('text', { timeout: 5_000 })

    // Open the type dropdown and select "date".
    await typeButton.click()
    await page.getByRole('menuitem', { name: 'date' }).click()

    // After override: the type button should now read "date" and the value
    // input should be type="date" (the ScalarField renders htmlType="date").
    await expect(typeButton).toHaveText('date', { timeout: 5_000 })
    const dateInput = row.locator('dd input[type="date"]')
    await expect(dateInput).toBeVisible({ timeout: 5_000 })

    // Reload the page — y-indexeddb restores the Y.Doc (including frontmatter_types)
    // from IndexedDB; the type override must survive.
    await page.reload()
    await expect(page).toHaveURL(new RegExp(`/note/${noteId}`), { timeout: 10_000 })

    // Wait for the widget to re-render with the same note after reload.
    await waitForProperty(page, 'due')

    // The type override stored in Y.Map("frontmatter_types") should still be "date".
    // If this assertion fails it is a real persistence bug — do NOT weaken it.
    const rowAfter = page.getByTestId('property-row-due')
    const typeButtonAfter = rowAfter.getByRole('button', { name: 'Property type' })
    await expect(typeButtonAfter).toHaveText('date', { timeout: 10_000 })
    const dateInputAfter = rowAfter.locator('dd input[type="date"]')
    await expect(dateInputAfter).toBeVisible({ timeout: 5_000 })

    await ctx.close()
  })
})
