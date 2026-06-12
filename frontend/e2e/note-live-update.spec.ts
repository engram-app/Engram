import { test, expect, type Page } from '@playwright/test'

/**
 * #277 — Two-session live-update behavior for the web SPA note viewer.
 *
 * Both tests bootstrap a user + vault + note via the REST API, open the note
 * in a browser, then mutate the note via a second REST call (simulating
 * another client — plugin push, MCP write, or another browser tab). The
 * Phoenix channel must propagate `note_changed` and trigger React Query
 * invalidation so the viewer re-renders without a manual reload.
 *
 * Editor-mode coverage verifies the `useRemoteUpdateBanner` hook surfaces a
 * banner instead of clobbering the user's unsaved draft.
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
  // Vault is created later by the spec (createVault helper). Just suppress
  // the checklist tour row so the dashboard doesn't intercept editor clicks.
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
 * Sign in by going to the target note URL first — AuthGuard redirects to
 * `/sign-in?return_to=...` and bounces back after sign-in completes.
 * Seed `engram.activeVaultId` on the sign-in page so it survives the post-
 * sign-in route change (same origin, same storage).
 */
async function signInForNote(
  page: Page,
  email: string,
  vaultId: number,
  noteId: number,
): Promise<void> {
  // Hitting /note/:id unauth → AuthGuard redirects to /sign-in?return_to=…
  await page.goto(`/note/${noteId}`)
  await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })

  // Seed active vault before sign-in completes so the post-redirect render
  // already has it (vault-switcher's auto-select wouldn't pick our new vault
  // before NotePage's first query fires).
  await page.evaluate((id) => {
    localStorage.setItem('engram.activeVaultId', String(id))
  }, vaultId)

  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password', { exact: true }).fill(PASS)
  await page.getByRole('button', { name: /sign in/i }).click()

  await expect(page).toHaveURL(new RegExp(`/note/${noteId}`), { timeout: 10_000 })
}

test.describe('SPA viewer live-update (#277)', () => {
  test('viewer re-renders when a remote client upserts the open note', async ({
    browser,
    baseURL,
  }) => {
    const email = `e2e-live-view-${Date.now()}@test.com`
    const token = await registerAndLogin(baseURL!, email)
    const vault = await createVault(baseURL!, token, `liveview-${Date.now()}`)
    const path = 'live-view.md'
    const { id: noteId } = await upsertNote(
      baseURL!,
      token,
      vault.id,
      path,
      '# Initial\n\nFirst body.',
    )

    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await signInForNote(page, email, vault.id, noteId)

    // `forceMount` on both Tabs.Content means the Edit panel is in the DOM
    // alongside Preview; scope assertions to the visible Preview panel.
    const preview = page.getByRole('tabpanel', { name: 'Preview' })
    await expect(preview.getByText('First body.')).toBeVisible({ timeout: 10_000 })

    // Remote upsert (simulates plugin push / MCP write / other web tab Save).
    await upsertNote(baseURL!, token, vault.id, path, '# Initial\n\nSecond body remote.')

    await expect(preview.getByText('Second body remote.')).toBeVisible({ timeout: 5_000 })
    await expect(preview.getByText('First body.')).toBeHidden()

    await ctx.close()
  })

  test('editor mode shows remote-update banner without losing local draft', async ({
    browser,
    baseURL,
  }) => {
    const email = `e2e-live-edit-${Date.now()}@test.com`
    const token = await registerAndLogin(baseURL!, email)
    const vault = await createVault(baseURL!, token, `liveedit-${Date.now()}`)
    const path = 'live-edit.md'
    const { id: noteId } = await upsertNote(
      baseURL!,
      token,
      vault.id,
      path,
      '# Initial\n\noriginal text.',
    )

    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await signInForNote(page, email, vault.id, noteId)

    const preview = page.getByRole('tabpanel', { name: 'Preview' })
    const editPanel = page.getByRole('tabpanel', { name: 'Edit' })
    await expect(preview.getByText('original text.')).toBeVisible({ timeout: 10_000 })

    // Switch into edit mode and type a local unsaved edit into CodeMirror.
    await page.getByRole('tab', { name: 'Edit' }).click()
    const editor = editPanel.locator('.cm-content')
    await editor.click()
    await page.keyboard.press('Control+End')
    await page.keyboard.type(' local-unsaved-edit')

    // Remote client lands an update while the editor is dirty.
    await upsertNote(baseURL!, token, vault.id, path, '# Initial\n\noriginal text. remote-edit')

    // Banner appears; draft is preserved (local-unsaved-edit still in editor).
    await expect(editPanel.getByText(/updated elsewhere/i)).toBeVisible({ timeout: 5_000 })
    await expect(editPanel.getByText('local-unsaved-edit')).toBeVisible()

    await ctx.close()
  })
})
