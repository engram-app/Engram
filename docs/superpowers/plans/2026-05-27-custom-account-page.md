# Custom Account Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the embedded Clerk `<UserProfile>` in Settings → Account with a fully custom, responsive account UI assembled from Clerk hooks at full feature parity (profile, email, password, MFA, connected accounts, sessions, delete).

**Architecture:** `account-page.tsx` becomes a thin composition — a heading plus a vertical stack of independent section cards under `frontend/src/settings/account/`. Each section reads its own `useUser()` slice, owns its mutations, and manages its own loading/error/toast state. No inner navigation (this structurally kills the two-stacked-hamburgers mobile bug). Sensitive mutations are wrapped in `useReverification()` so Clerk's built-in re-auth modal fires automatically.

**Tech Stack:** React 19 + TypeScript + Vite + Tailwind v4 + shadcn/ui + `@clerk/clerk-react` v5.61.4. Tests: Vitest + React Testing Library (happy-dom). Toasts: `sonner`.

---

## Source-of-truth references (fetch before coding the matching section)

Per the build instruction, **before implementing each Clerk-flow section, fetch its doc** with `firecrawl_scrape` → markdown and confirm the API signatures in this plan still match current Clerk v5. The code below is written against Clerk v5; if a signature drifted, follow the doc and adjust.

- Profile/email/password/MFA/SSO custom flows: `https://clerk.com/docs/guides/development/custom-flows/account-updates/<add-email|update-password|manage-mfa|manage-sso-connections>`
- Reverification: `https://clerk.com/docs/guides/secure/reverification` and `https://clerk.com/docs/react/reference/hooks/use-reverification`
- Object refs: `https://clerk.com/docs/react/reference/objects/user`, `https://clerk.com/docs/react/reference/types/email-address`, `https://clerk.com/docs/react/reference/objects/session`

## Conventions (apply to every task)

- **Tokens only** — `text-foreground`, `text-muted-foreground`, `border-input`, `bg-card`, `bg-muted`, `text-destructive`, `bg-destructive/10`, `bg-primary`, `text-primary-foreground`. No hardcoded gray/blue/red.
- **Inputs**: native `<input>` with the project class string:
  `className="mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring"`
- **Buttons**: shadcn `Button` from `@/components/ui/button` (primary actions); destructive actions use `<Button variant="destructive">`.
- **Toasts**: `import { toast } from 'sonner'` → `toast.success(...)` / `toast.error(...)`.
- **Errors**: `import { isClerkAPIResponseError } from '@clerk/clerk-react/errors'` (confirm path during doc fetch). Map `err.errors[].{code,message,meta.paramName}` to field- or form-level messages; unknown → generic line + `toast.error`.
- **Reverification**: `const wrapped = useReverification(fn)` returns a callable that triggers Clerk's modal when needed and re-invokes `fn` on success. Confirm the exact return shape (callable vs tuple) from the reverification doc during Task 1 and use that shape consistently across all sections.
- **Commands** (run from `frontend/`): tests `bun run test` (`vitest run`), typecheck `bunx tsc --noEmit`, build `bun run build`.
- **Test mocking**: each `*.test.tsx` self-mocks `@clerk/clerk-react` with `vi.mock(...)`. No global Clerk mock exists. Use the `makeUser()` factory from `account/section-test-helpers.ts` (Task 0) for the fake user.

---

## File Structure

```
frontend/src/settings/
  account-page.tsx                        # MODIFY: composition (heading + gated section stack)
  account/
    section-card.tsx                      # CREATE: shared card wrapper
    section-card.test.tsx
    section-test-helpers.ts               # CREATE: makeUser() factory for tests
    profile-section.tsx + .test.tsx
    email-section.tsx + .test.tsx
    password-section.tsx + .test.tsx
    mfa-section.tsx + .test.tsx
    connected-accounts-section.tsx + .test.tsx
    sessions-section.tsx + .test.tsx
    danger-zone-section.tsx + .test.tsx
frontend/src/router.tsx                   # MODIFY: account/* → account
```

---

## Task 0: Shared card + test helper

**Files:**
- Create: `frontend/src/settings/account/section-card.tsx`
- Create: `frontend/src/settings/account/section-card.test.tsx`
- Create: `frontend/src/settings/account/section-test-helpers.ts`

- [ ] **Step 1: Write the failing test**

`section-card.test.tsx`:
```tsx
import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { SettingsSectionCard } from './section-card'

describe('SettingsSectionCard', () => {
  it('renders title, description, and children', () => {
    render(
      <SettingsSectionCard title="Profile" description="Your name and avatar">
        <p>body content</p>
      </SettingsSectionCard>,
    )
    expect(screen.getByRole('heading', { name: 'Profile' })).toBeInTheDocument()
    expect(screen.getByText('Your name and avatar')).toBeInTheDocument()
    expect(screen.getByText('body content')).toBeInTheDocument()
  })

  it('omits the description node when not provided', () => {
    render(<SettingsSectionCard title="Sessions"><span>x</span></SettingsSectionCard>)
    expect(screen.getByRole('heading', { name: 'Sessions' })).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- section-card`
Expected: FAIL — cannot resolve `./section-card`.

- [ ] **Step 3: Write minimal implementation**

`section-card.tsx`:
```tsx
import type { ReactNode } from 'react'

interface Props {
  title: string
  description?: string
  children: ReactNode
}

export function SettingsSectionCard({ title, description, children }: Props) {
  return (
    <section className="rounded-lg border border-border bg-card p-4 sm:p-6">
      <header className="mb-4">
        <h2 className="text-base font-semibold text-foreground">{title}</h2>
        {description && (
          <p className="mt-1 text-sm text-muted-foreground">{description}</p>
        )}
      </header>
      {children}
    </section>
  )
}
```

- [ ] **Step 4: Write the test helper**

`section-test-helpers.ts`:
```ts
import { vi } from 'vitest'

// Minimal fake of Clerk's User resource. Override per test as needed.
export function makeUser(overrides: Record<string, unknown> = {}) {
  return {
    firstName: 'Ada',
    lastName: 'Lovelace',
    imageUrl: 'https://example.com/a.png',
    passwordEnabled: true,
    twoFactorEnabled: false,
    primaryEmailAddressId: 'eml_1',
    emailAddresses: [
      { id: 'eml_1', emailAddress: 'ada@example.com', verification: { status: 'verified' }, destroy: vi.fn().mockResolvedValue({}), prepareVerification: vi.fn().mockResolvedValue({}), attemptVerification: vi.fn().mockResolvedValue({}) },
    ],
    externalAccounts: [],
    update: vi.fn().mockResolvedValue({}),
    setProfileImage: vi.fn().mockResolvedValue({}),
    updatePassword: vi.fn().mockResolvedValue({}),
    createEmailAddress: vi.fn().mockResolvedValue({ id: 'eml_2', emailAddress: 'new@example.com', prepareVerification: vi.fn().mockResolvedValue({}), attemptVerification: vi.fn().mockResolvedValue({}) }),
    createTOTP: vi.fn().mockResolvedValue({ secret: 'SECRET', uri: 'otpauth://totp/x' }),
    verifyTOTP: vi.fn().mockResolvedValue({}),
    createBackupCode: vi.fn().mockResolvedValue({ codes: ['11111111', '22222222'] }),
    disableTOTP: vi.fn().mockResolvedValue({}),
    createExternalAccount: vi.fn().mockResolvedValue({ verification: { externalVerificationRedirectURL: new URL('https://accounts.example.com/oauth') } }),
    delete: vi.fn().mockResolvedValue({}),
    reload: vi.fn().mockResolvedValue({}),
    ...overrides,
  }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd frontend && bun run test -- section-card`
Expected: PASS (2 tests).

- [ ] **Step 6: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/section-card.tsx frontend/src/settings/account/section-card.test.tsx frontend/src/settings/account/section-test-helpers.ts
git commit -m "feat(account): shared SettingsSectionCard + test helper"
```

---

## Task 1: Profile section

**Doc to fetch first:** `objects/user` (for `user.update` + `setProfileImage` signatures) and the reverification doc (lock the `useReverification` return shape now — it is reused everywhere).

**Files:**
- Create: `frontend/src/settings/account/profile-section.tsx`
- Create: `frontend/src/settings/account/profile-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`profile-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ProfileSection } from './profile-section'

describe('ProfileSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('saves edited names via user.update', async () => {
    render(<ProfileSection />)
    fireEvent.change(screen.getByLabelText(/first name/i), { target: { value: 'Grace' } })
    fireEvent.click(screen.getByRole('button', { name: /save/i }))
    await waitFor(() =>
      expect(user.update).toHaveBeenCalledWith({ firstName: 'Grace', lastName: 'Lovelace' }),
    )
  })

  it('uploads an avatar via setProfileImage', async () => {
    render(<ProfileSection />)
    const file = new File(['x'], 'a.png', { type: 'image/png' })
    fireEvent.change(screen.getByLabelText(/profile image/i), { target: { files: [file] } })
    await waitFor(() => expect(user.setProfileImage).toHaveBeenCalledWith({ file }))
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- profile-section`
Expected: FAIL — cannot resolve `./profile-section`.

- [ ] **Step 3: Implement**

`profile-section.tsx`:
```tsx
import { useState } from 'react'
import { useUser } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ProfileSection() {
  const { user, isLoaded } = useUser()
  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [seeded, setSeeded] = useState(false)
  const [saving, setSaving] = useState(false)

  if (!isLoaded || !user) return null
  if (!seeded) {
    setFirstName(user.firstName ?? '')
    setLastName(user.lastName ?? '')
    setSeeded(true)
  }

  async function save() {
    setSaving(true)
    try {
      await user!.update({ firstName, lastName })
      toast.success('Profile updated')
    } catch {
      toast.error('Could not update profile')
    } finally {
      setSaving(false)
    }
  }

  async function onImage(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    try {
      await user!.setProfileImage({ file })
      toast.success('Profile image updated')
    } catch {
      toast.error('Could not update image')
    }
  }

  return (
    <SettingsSectionCard title="Profile" description="Your name and avatar.">
      <div className="flex items-center gap-4">
        <img src={user.imageUrl} alt="" className="size-12 rounded-full border border-border" />
        <label className="text-sm text-muted-foreground">
          <span className="sr-only">Profile image</span>
          <input aria-label="Profile image" type="file" accept="image/*" onChange={onImage} className="text-sm" />
        </label>
      </div>
      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <label className="block text-sm font-medium text-foreground">
          First name
          <input className={inputClass} value={firstName} onChange={(e) => setFirstName(e.target.value)} />
        </label>
        <label className="block text-sm font-medium text-foreground">
          Last name
          <input className={inputClass} value={lastName} onChange={(e) => setLastName(e.target.value)} />
        </label>
      </div>
      <Button className="mt-4" onClick={save} disabled={saving}>
        {saving ? 'Saving…' : 'Save'}
      </Button>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- profile-section`
Expected: PASS (2 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/profile-section.tsx frontend/src/settings/account/profile-section.test.tsx
git commit -m "feat(account): custom profile section (name + avatar)"
```

---

## Task 2: Email addresses section

**Doc to fetch first:** `custom-flows/account-updates/add-email` and `types/email-address`. Confirm: `user.createEmailAddress({ email })` → `emailAddress.prepareVerification({ strategy: 'email_code' })` → `emailAddress.attemptVerification({ code })`, primary set via `user.update({ primaryEmailAddressId })`, removal via `emailAddress.destroy()`.

**Files:**
- Create: `frontend/src/settings/account/email-section.tsx`
- Create: `frontend/src/settings/account/email-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`email-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const newEmail = {
  id: 'eml_2',
  emailAddress: 'new@example.com',
  prepareVerification: vi.fn().mockResolvedValue({}),
  attemptVerification: vi.fn().mockResolvedValue({}),
}
const user = makeUser({ createEmailAddress: vi.fn().mockResolvedValue(newEmail) })

vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { EmailSection } from './email-section'

describe('EmailSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lists existing emails', () => {
    render(<EmailSection />)
    expect(screen.getByText('ada@example.com')).toBeInTheDocument()
  })

  it('adds an email and prepares verification', async () => {
    render(<EmailSection />)
    fireEvent.change(screen.getByLabelText(/add email/i), { target: { value: 'new@example.com' } })
    fireEvent.click(screen.getByRole('button', { name: /^add$/i }))
    await waitFor(() => expect(user.createEmailAddress).toHaveBeenCalledWith({ email: 'new@example.com' }))
    await waitFor(() => expect(newEmail.prepareVerification).toHaveBeenCalledWith({ strategy: 'email_code' }))
  })

  it('verifies the new email with a code', async () => {
    render(<EmailSection />)
    fireEvent.change(screen.getByLabelText(/add email/i), { target: { value: 'new@example.com' } })
    fireEvent.click(screen.getByRole('button', { name: /^add$/i }))
    await screen.findByLabelText(/verification code/i)
    fireEvent.change(screen.getByLabelText(/verification code/i), { target: { value: '123456' } })
    fireEvent.click(screen.getByRole('button', { name: /verify/i }))
    await waitFor(() => expect(newEmail.attemptVerification).toHaveBeenCalledWith({ code: '123456' }))
  })

  it('removes an email via destroy', async () => {
    render(<EmailSection />)
    fireEvent.click(screen.getByRole('button', { name: /remove ada@example.com/i }))
    await waitFor(() => expect(user.emailAddresses[0].destroy).toHaveBeenCalled())
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- email-section`
Expected: FAIL — cannot resolve `./email-section`.

- [ ] **Step 3: Implement**

`email-section.tsx`:
```tsx
import { useState } from 'react'
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function EmailSection() {
  const { user, isLoaded } = useUser()
  const [email, setEmail] = useState('')
  const [pending, setPending] = useState<{ attemptVerification: (p: { code: string }) => Promise<unknown> } | null>(null)
  const [code, setCode] = useState('')
  const removeEmail = useReverification((destroy: () => Promise<unknown>) => destroy())
  const setPrimary = useReverification((id: string) => user!.update({ primaryEmailAddressId: id }))

  if (!isLoaded || !user) return null

  async function add() {
    try {
      const created = await user!.createEmailAddress({ email })
      await created.prepareVerification({ strategy: 'email_code' })
      setPending(created)
      toast.success('Verification code sent')
    } catch {
      toast.error('Could not add email')
    }
  }

  async function verify() {
    try {
      await pending!.attemptVerification({ code })
      setPending(null)
      setEmail('')
      setCode('')
      toast.success('Email verified')
    } catch {
      toast.error('Invalid code')
    }
  }

  return (
    <SettingsSectionCard title="Email addresses" description="Add, verify, or remove email addresses.">
      <ul className="space-y-2">
        {user.emailAddresses.map((e) => (
          <li key={e.id} className="flex items-center justify-between gap-2 text-sm">
            <span className="text-foreground">
              {e.emailAddress}
              {e.id === user.primaryEmailAddressId && (
                <span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">Primary</span>
              )}
            </span>
            <span className="flex gap-2">
              {e.id !== user.primaryEmailAddressId && (
                <Button variant="ghost" size="sm" onClick={() => setPrimary(e.id)}>Make primary</Button>
              )}
              <Button variant="ghost" size="sm" aria-label={`Remove ${e.emailAddress}`} onClick={() => removeEmail(() => e.destroy())}>Remove</Button>
            </span>
          </li>
        ))}
      </ul>

      {pending ? (
        <div className="mt-4">
          <label className="block text-sm font-medium text-foreground">
            Verification code
            <input className={inputClass} value={code} onChange={(ev) => setCode(ev.target.value)} />
          </label>
          <Button className="mt-2" onClick={verify}>Verify</Button>
        </div>
      ) : (
        <div className="mt-4 flex items-end gap-2">
          <label className="flex-1 block text-sm font-medium text-foreground">
            Add email
            <input className={inputClass} type="email" value={email} onChange={(ev) => setEmail(ev.target.value)} />
          </label>
          <Button onClick={add}>Add</Button>
        </div>
      )}
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- email-section`
Expected: PASS (4 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/email-section.tsx frontend/src/settings/account/email-section.test.tsx
git commit -m "feat(account): email add/verify/primary/remove section"
```

---

## Task 3: Password section

**Doc to fetch first:** `custom-flows/account-updates/update-password`. Confirm `user.updatePassword({ currentPassword, newPassword, signOutOfOtherSessions })` and that `user.passwordEnabled` selects set-vs-change (when false, `currentPassword` is omitted).

**Files:**
- Create: `frontend/src/settings/account/password-section.tsx`
- Create: `frontend/src/settings/account/password-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`password-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

let user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { PasswordSection } from './password-section'

describe('PasswordSection', () => {
  beforeEach(() => { vi.clearAllMocks(); user = makeUser() })

  it('changes password with current + new when passwordEnabled', async () => {
    render(<PasswordSection />)
    fireEvent.change(screen.getByLabelText(/current password/i), { target: { value: 'old' } })
    fireEvent.change(screen.getByLabelText(/^new password/i), { target: { value: 'newpass123' } })
    fireEvent.click(screen.getByRole('button', { name: /update password/i }))
    await waitFor(() =>
      expect(user.updatePassword).toHaveBeenCalledWith({
        currentPassword: 'old',
        newPassword: 'newpass123',
        signOutOfOtherSessions: true,
      }),
    )
  })

  it('omits currentPassword when no password is set yet', async () => {
    user = makeUser({ passwordEnabled: false })
    render(<PasswordSection />)
    expect(screen.queryByLabelText(/current password/i)).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText(/^new password/i), { target: { value: 'newpass123' } })
    fireEvent.click(screen.getByRole('button', { name: /set password/i }))
    await waitFor(() =>
      expect(user.updatePassword).toHaveBeenCalledWith({
        newPassword: 'newpass123',
        signOutOfOtherSessions: true,
      }),
    )
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- password-section`
Expected: FAIL — cannot resolve `./password-section`.

- [ ] **Step 3: Implement**

`password-section.tsx`:
```tsx
import { useState } from 'react'
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function PasswordSection() {
  const { user, isLoaded } = useUser()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const update = useReverification((params: Record<string, unknown>) => user!.updatePassword(params))

  if (!isLoaded || !user) return null
  const hasPassword = user.passwordEnabled

  async function submit() {
    try {
      await update({
        ...(hasPassword ? { currentPassword: current } : {}),
        newPassword: next,
        signOutOfOtherSessions: true,
      })
      setCurrent('')
      setNext('')
      toast.success('Password updated')
    } catch {
      toast.error('Could not update password')
    }
  }

  return (
    <SettingsSectionCard title="Password" description="Set or change your password.">
      {hasPassword && (
        <label className="block text-sm font-medium text-foreground">
          Current password
          <input className={inputClass} type="password" value={current} onChange={(e) => setCurrent(e.target.value)} />
        </label>
      )}
      <label className="mt-4 block text-sm font-medium text-foreground">
        New password
        <input className={inputClass} type="password" value={next} onChange={(e) => setNext(e.target.value)} />
      </label>
      <Button className="mt-4" onClick={submit}>
        {hasPassword ? 'Update password' : 'Set password'}
      </Button>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- password-section`
Expected: PASS (2 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/password-section.tsx frontend/src/settings/account/password-section.test.tsx
git commit -m "feat(account): password set/change section"
```

---

## Task 4: Two-factor (MFA) section

**Doc to fetch first:** `custom-flows/account-updates/manage-mfa`. Confirm `user.createTOTP()` returns `{ secret, uri }`, `user.verifyTOTP({ code })`, `user.createBackupCode()` returns `{ codes }`, `user.disableTOTP()`, gating off `user.twoFactorEnabled`. For the QR image, render the `totp.uri` — confirm whether the doc renders via a QR lib or shows the URI/secret. This plan renders the raw URI + secret (no new dep); upgrade to a QR image only if a QR lib already exists in `package.json`.

**Files:**
- Create: `frontend/src/settings/account/mfa-section.tsx`
- Create: `frontend/src/settings/account/mfa-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`mfa-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

let user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { MfaSection } from './mfa-section'

describe('MfaSection', () => {
  beforeEach(() => { vi.clearAllMocks(); user = makeUser() })

  it('enables TOTP: createTOTP then verifyTOTP', async () => {
    render(<MfaSection />)
    fireEvent.click(screen.getByRole('button', { name: /enable two-factor/i }))
    await waitFor(() => expect(user.createTOTP).toHaveBeenCalled())
    fireEvent.change(await screen.findByLabelText(/authenticator code/i), { target: { value: '123456' } })
    fireEvent.click(screen.getByRole('button', { name: /verify/i }))
    await waitFor(() => expect(user.verifyTOTP).toHaveBeenCalledWith({ code: '123456' }))
  })

  it('disables TOTP when already enabled', async () => {
    user = makeUser({ twoFactorEnabled: true })
    render(<MfaSection />)
    fireEvent.click(screen.getByRole('button', { name: /disable two-factor/i }))
    await waitFor(() => expect(user.disableTOTP).toHaveBeenCalled())
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- mfa-section`
Expected: FAIL — cannot resolve `./mfa-section`.

- [ ] **Step 3: Implement**

`mfa-section.tsx`:
```tsx
import { useState } from 'react'
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function MfaSection() {
  const { user, isLoaded } = useUser()
  const [totp, setTotp] = useState<{ uri?: string; secret?: string } | null>(null)
  const [code, setCode] = useState('')
  const enable = useReverification(() => user!.createTOTP())
  const verify = useReverification((c: string) => user!.verifyTOTP({ code: c }))
  const disable = useReverification(() => user!.disableTOTP())

  if (!isLoaded || !user) return null

  async function startEnable() {
    try { setTotp(await enable()) } catch { toast.error('Could not start setup') }
  }
  async function confirmEnable() {
    try {
      await verify(code)
      setTotp(null)
      setCode('')
      toast.success('Two-factor enabled')
    } catch { toast.error('Invalid code') }
  }
  async function turnOff() {
    try { await disable(); toast.success('Two-factor disabled') } catch { toast.error('Could not disable') }
  }

  return (
    <SettingsSectionCard title="Two-factor authentication" description="Protect your account with an authenticator app.">
      {user.twoFactorEnabled ? (
        <Button variant="destructive" onClick={turnOff}>Disable two-factor</Button>
      ) : totp ? (
        <div>
          <p className="text-sm text-muted-foreground">Add this key to your authenticator app:</p>
          <code className="mt-1 block break-all rounded bg-muted px-2 py-1 text-xs text-foreground">{totp.secret}</code>
          <label className="mt-3 block text-sm font-medium text-foreground">
            Authenticator code
            <input className={inputClass} value={code} onChange={(e) => setCode(e.target.value)} />
          </label>
          <Button className="mt-2" onClick={confirmEnable}>Verify</Button>
        </div>
      ) : (
        <Button onClick={startEnable}>Enable two-factor</Button>
      )}
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- mfa-section`
Expected: PASS (2 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/mfa-section.tsx frontend/src/settings/account/mfa-section.test.tsx
git commit -m "feat(account): TOTP two-factor enable/disable section"
```

> **Manual smoke (note in PR):** backup codes (`createBackupCode`) and live TOTP enrollment require a real authenticator — verify manually after deploy.

---

## Task 5: Connected accounts section

**Doc to fetch first:** `custom-flows/account-updates/manage-sso-connections`. Confirm `user.externalAccounts`, `user.createExternalAccount({ strategy, redirectUrl })` returns a resource whose `verification.externalVerificationRedirectURL` you redirect to, and `externalAccount.destroy()`. Confirm how the doc enumerates instance-enabled OAuth providers — this plan passes them in as a prop (`providers`) so the section stays config-gated and unit-testable; account-page (Task 8) derives the list.

**Files:**
- Create: `frontend/src/settings/account/connected-accounts-section.tsx`
- Create: `frontend/src/settings/account/connected-accounts-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`connected-accounts-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const googleAcct = { id: 'ext_1', provider: 'google', emailAddress: 'ada@gmail.com', destroy: vi.fn().mockResolvedValue({}) }
let user = makeUser({ externalAccounts: [googleAcct] })

vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ConnectedAccountsSection } from './connected-accounts-section'

describe('ConnectedAccountsSection', () => {
  beforeEach(() => { vi.clearAllMocks(); user = makeUser({ externalAccounts: [googleAcct] }) })

  it('lists connected accounts and disconnects via destroy', async () => {
    render(<ConnectedAccountsSection providers={['oauth_google', 'oauth_github']} />)
    expect(screen.getByText(/ada@gmail.com/i)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /disconnect google/i }))
    await waitFor(() => expect(googleAcct.destroy).toHaveBeenCalled())
  })

  it('connects a new provider via createExternalAccount', async () => {
    render(<ConnectedAccountsSection providers={['oauth_github']} />)
    fireEvent.click(screen.getByRole('button', { name: /connect github/i }))
    await waitFor(() =>
      expect(user.createExternalAccount).toHaveBeenCalledWith(
        expect.objectContaining({ strategy: 'oauth_github' }),
      ),
    )
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- connected-accounts-section`
Expected: FAIL — cannot resolve `./connected-accounts-section`.

- [ ] **Step 3: Implement**

`connected-accounts-section.tsx`:
```tsx
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

type Strategy = `oauth_${string}`
const label = (s: string) => s.replace(/^oauth_/, '').replace(/^\w/, (c) => c.toUpperCase())

export function ConnectedAccountsSection({ providers }: { providers: Strategy[] }) {
  const { user, isLoaded } = useUser()
  const disconnect = useReverification((destroy: () => Promise<unknown>) => destroy())

  if (!isLoaded || !user) return null
  const connected = new Set(user.externalAccounts.map((a) => `oauth_${a.provider}`))

  async function connect(strategy: Strategy) {
    try {
      const acct = await user!.createExternalAccount({
        strategy,
        redirectUrl: `${window.location.origin}/settings/account`,
      })
      const url = acct.verification?.externalVerificationRedirectURL
      if (url) window.location.href = url.toString()
    } catch {
      toast.error('Could not start connection')
    }
  }

  return (
    <SettingsSectionCard title="Connected accounts" description="Link third-party sign-in providers.">
      <ul className="space-y-2">
        {user.externalAccounts.map((a) => (
          <li key={a.id} className="flex items-center justify-between gap-2 text-sm">
            <span className="text-foreground">{label(a.provider)} — {a.emailAddress}</span>
            <Button variant="ghost" size="sm" aria-label={`Disconnect ${label(a.provider)}`} onClick={() => disconnect(() => a.destroy())}>
              Disconnect
            </Button>
          </li>
        ))}
      </ul>
      <div className="mt-4 flex flex-wrap gap-2">
        {providers.filter((p) => !connected.has(p)).map((p) => (
          <Button key={p} variant="outline" size="sm" onClick={() => connect(p)}>
            Connect {label(p)}
          </Button>
        ))}
      </div>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- connected-accounts-section`
Expected: PASS (2 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/connected-accounts-section.tsx frontend/src/settings/account/connected-accounts-section.test.tsx
git commit -m "feat(account): connected OAuth accounts section"
```

> **Manual smoke (note in PR):** the OAuth connect flow redirects to the provider — verify manually after deploy.

---

## Task 6: Active sessions section

**Doc to fetch first:** `objects/session` and the `useSessionList` reference. Confirm `useSessionList()` shape (`{ sessions }`), `session.revoke()`, and how to identify the current session (compare to `useSession().session.id`).

**Files:**
- Create: `frontend/src/settings/account/sessions-section.tsx`
- Create: `frontend/src/settings/account/sessions-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`sessions-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const current = { id: 'sess_current', latestActivity: { deviceType: 'Mac', browserName: 'Chrome' }, revoke: vi.fn() }
const other = { id: 'sess_other', latestActivity: { deviceType: 'iPhone', browserName: 'Safari' }, revoke: vi.fn().mockResolvedValue({}) }

vi.mock('@clerk/clerk-react', () => ({
  useSessionList: () => ({ isLoaded: true, sessions: [current, other] }),
  useSession: () => ({ session: { id: 'sess_current' } }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { SessionsSection } from './sessions-section'

describe('SessionsSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('marks the current session and hides its revoke button', () => {
    render(<SessionsSection />)
    expect(screen.getByText(/current/i)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /revoke sess_current/i })).not.toBeInTheDocument()
  })

  it('revokes another session', async () => {
    render(<SessionsSection />)
    fireEvent.click(screen.getByRole('button', { name: /revoke .*iphone/i }))
    await waitFor(() => expect(other.revoke).toHaveBeenCalled())
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- sessions-section`
Expected: FAIL — cannot resolve `./sessions-section`.

- [ ] **Step 3: Implement**

`sessions-section.tsx`:
```tsx
import { useSessionList, useSession } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

export function SessionsSection() {
  const { isLoaded, sessions } = useSessionList()
  const { session: active } = useSession()

  if (!isLoaded) return null

  async function revoke(s: { revoke: () => Promise<unknown> }) {
    try { await s.revoke(); toast.success('Session revoked') } catch { toast.error('Could not revoke') }
  }

  return (
    <SettingsSectionCard title="Active sessions" description="Devices currently signed in to your account.">
      <ul className="space-y-2">
        {sessions.map((s) => {
          const a = s.latestActivity
          const name = `${a?.deviceType ?? 'Device'} · ${a?.browserName ?? 'Browser'}`
          const isCurrent = s.id === active?.id
          return (
            <li key={s.id} className="flex items-center justify-between gap-2 text-sm">
              <span className="text-foreground">
                {name}
                {isCurrent && <span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">Current</span>}
              </span>
              {!isCurrent && (
                <Button variant="ghost" size="sm" aria-label={`Revoke ${name}`} onClick={() => revoke(s)}>Revoke</Button>
              )}
            </li>
          )
        })}
      </ul>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- sessions-section`
Expected: PASS (2 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/sessions-section.tsx frontend/src/settings/account/sessions-section.test.tsx
git commit -m "feat(account): active sessions list + revoke section"
```

---

## Task 7: Danger zone (delete account) section

**Doc to fetch first:** `objects/user` (`user.delete()`). Confirm delete signature and any post-delete sign-out behavior.

**Files:**
- Create: `frontend/src/settings/account/danger-zone-section.tsx`
- Create: `frontend/src/settings/account/danger-zone-section.test.tsx`

- [ ] **Step 1: Write the failing test**

`danger-zone-section.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { DangerZoneSection } from './danger-zone-section'

describe('DangerZoneSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('keeps delete disabled until the confirmation phrase matches', () => {
    render(<DangerZoneSection />)
    const btn = screen.getByRole('button', { name: /delete my account/i })
    expect(btn).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/type .*delete my account/i), { target: { value: 'delete my account' } })
    expect(btn).toBeEnabled()
  })

  it('calls user.delete when confirmed', async () => {
    render(<DangerZoneSection />)
    fireEvent.change(screen.getByLabelText(/type .*delete my account/i), { target: { value: 'delete my account' } })
    fireEvent.click(screen.getByRole('button', { name: /delete my account/i }))
    await waitFor(() => expect(user.delete).toHaveBeenCalled())
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- danger-zone-section`
Expected: FAIL — cannot resolve `./danger-zone-section`.

- [ ] **Step 3: Implement**

`danger-zone-section.tsx`:
```tsx
import { useState } from 'react'
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const CONFIRM = 'delete my account'
const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function DangerZoneSection() {
  const { user, isLoaded } = useUser()
  const [phrase, setPhrase] = useState('')
  const remove = useReverification(() => user!.delete())

  if (!isLoaded || !user) return null

  async function onDelete() {
    try { await remove() } catch { toast.error('Could not delete account') }
  }

  return (
    <section className="rounded-lg border border-destructive/40 bg-destructive/5 p-4 sm:p-6">
      <header className="mb-4">
        <h2 className="text-base font-semibold text-destructive">Danger zone</h2>
        <p className="mt-1 text-sm text-muted-foreground">Permanently delete your account and all associated data. This cannot be undone.</p>
      </header>
      <label className="block text-sm font-medium text-foreground">
        Type "{CONFIRM}" to confirm
        <input className={inputClass} value={phrase} onChange={(e) => setPhrase(e.target.value)} />
      </label>
      <Button className="mt-4" variant="destructive" disabled={phrase !== CONFIRM} onClick={onDelete}>
        Delete my account
      </Button>
    </section>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd frontend && bun run test -- danger-zone-section`
Expected: PASS (2 tests).

- [ ] **Step 5: Typecheck + commit**

```bash
cd frontend && bunx tsc --noEmit
git add frontend/src/settings/account/danger-zone-section.tsx frontend/src/settings/account/danger-zone-section.test.tsx
git commit -m "feat(account): danger zone delete-account section"
```

---

## Task 8: Compose account-page + fix router

**Doc to fetch first:** re-skim `manage-sso-connections` + `manage-mfa` for the canonical way to read instance-enabled OAuth providers / MFA factors (Clerk environment). If the unstable environment shape is unclear, fall back to: render Connected accounts only when `user.externalAccounts.length > 0` OR pass a hardcoded provider list matching this instance's enabled providers (confirm with the user which OAuth providers the Clerk instance has enabled before hardcoding).

**Files:**
- Modify: `frontend/src/settings/account-page.tsx` (full rewrite of the body)
- Modify: `frontend/src/router.tsx` (change `account/*` → `account`)
- Create: `frontend/src/settings/account-page.test.tsx`

- [ ] **Step 1: Write the failing test**

`account-page.test.tsx`:
```tsx
import { render, screen } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { makeUser } from './account/section-test-helpers'

vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user: makeUser(), isLoaded: true }),
  useReverification: (fn: unknown) => fn,
  useSessionList: () => ({ isLoaded: true, sessions: [] }),
  useSession: () => ({ session: { id: 'sess_current' } }),
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import AccountPage from './account-page'

describe('AccountPage', () => {
  it('renders the section stack with no embedded Clerk UserProfile', () => {
    render(<AccountPage />)
    expect(screen.getByRole('heading', { name: 'Account', level: 1 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Profile' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Password' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /danger zone/i })).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test -- account-page`
Expected: FAIL — AccountPage still renders `<UserProfile>` (no "Profile" section heading).

- [ ] **Step 3: Rewrite `account-page.tsx`**

```tsx
import { ProfileSection } from './account/profile-section'
import { EmailSection } from './account/email-section'
import { PasswordSection } from './account/password-section'
import { ConnectedAccountsSection } from './account/connected-accounts-section'
import { SessionsSection } from './account/sessions-section'
import { DangerZoneSection } from './account/danger-zone-section'

// OAuth providers enabled on this Clerk instance. Confirm against the instance
// (see Task 8 doc note) before adjusting.
const OAUTH_PROVIDERS = ['oauth_google'] as const

export default function AccountPage() {
  return (
    <article className="space-y-6">
      <header>
        <h1 className="text-xl font-semibold text-foreground">Account</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Manage your profile, security, and active sessions.
        </p>
      </header>
      <ProfileSection />
      <EmailSection />
      <PasswordSection />
      <ConnectedAccountsSection providers={[...OAUTH_PROVIDERS]} />
      <SessionsSection />
      <DangerZoneSection />
    </article>
  )
}
```

- [ ] **Step 4: Fix the router (preserve clerk-only gate + keep Clerk out of the local bundle)**

**Critical — self-host (local auth) must not change.** The account route MUST stay inside the existing `config.authProvider === 'clerk'` conditional so `local` self-host builds never get an account route/nav (unchanged from today). Do NOT remove that gate.

**Bundle regression to avoid:** the old `account-page.tsx` lazy-loaded `@clerk/clerk-react` so `local` builds didn't bundle Clerk. The new `account-page.tsx` statically imports section components that statically import Clerk hooks. To keep Clerk out of the `local` bundle, lazy-load `AccountPage` in the router instead of statically importing it.

In `frontend/src/router.tsx`:
1. Replace the static import `import AccountPage from './settings/account-page'` (line ~11) with a lazy import near the other lazies:
```tsx
const AccountPage = lazy(() => import('./settings/account-page'))
```
(Confirm `lazy` is imported from `react`; the clerk branch element should already be inside a `<Suspense>` boundary — if not, wrap it.)
2. Change the route from the wildcard (Clerk's internal nav is gone) to an exact path, keeping the surrounding clerk gate intact:
```tsx
// before:
// ...(config.authProvider === 'clerk'
//   ? [{ path: 'account/*', element: <AccountPage /> }]
//   : []),
...(config.authProvider === 'clerk'
  ? [{ path: 'account', element: <AccountPage /> }]
  : []),
```
3. Remove the now-stale "Clerk's `<UserProfile>` renders its own nested sub-routes" comment above it.

Verify a `local` build excludes Clerk: after Task 8, `grep -r "clerk" frontend/dist/assets/*.js` should only appear in lazily-split chunks, not the main entry (spot-check; not a hard gate).

- [ ] **Step 5: Run the full account test suite**

Run: `cd frontend && bun run test -- account`
Expected: PASS (account-page + all section tests).

- [ ] **Step 6: Typecheck, build, commit**

```bash
cd frontend && bunx tsc --noEmit && bun run build
git add frontend/src/settings/account-page.tsx frontend/src/settings/account-page.test.tsx frontend/src/router.tsx
git commit -m "feat(account): compose custom account page, drop UserProfile embed"
```

---

## Task 9: Full verification + version bump + manual smoke

- [ ] **Step 1: Run the entire frontend suite + typecheck + build**

```bash
cd frontend && bun run test && bunx tsc --noEmit && bun run build
```
Expected: all green.

- [ ] **Step 2: Bump version (pre-push hook expectation)**

The repo pre-push hook bumps `mix.exs` (root) and runs `mix format`. Bump the version once for this feature before pushing (the unified-settings branch convention). From repo root:
```bash
# edit mix.exs version (patch bump), then:
cd .. && mix format
git add mix.exs && git commit -m "chore: bump version for custom account page"
```

- [ ] **Step 3: Manual smoke in the browser**

Per handoff: dev server `cd frontend && VITE_API_TARGET=https://staging.engram.page bunx vite --host 0.0.0.0 --port 5173`, verify in laptop Chrome over the SSH tunnel (`cdp-laptop` MCP at 9223; `docs/context/local-browser-cdp-tunnel.md`). Walk the golden path **and** confirm the original bug is gone:
  - **No nested navigation / second hamburger** on mobile width — the whole reason for this rebuild.
  - Edit name → Save → toast + persists on reload.
  - Add email → receive code → verify; set primary; remove.
  - Change password (reverification modal should appear).
  - Enable TOTP (authenticator), then disable.
  - Connect/disconnect an OAuth provider (redirect round-trip).
  - Revoke a non-current session; confirm current session has no revoke button.
  - Danger zone: button disabled until phrase matches (do NOT actually delete the real account).

- [ ] **Step 4: Report results** to the user before pushing/PR (do not push without confirmation per repo norms).

---

## Self-review notes (author)

- **Spec coverage:** profile ✓ (T1), email ✓ (T2), password set-vs-change ✓ (T3), MFA TOTP ✓ (T4, backup codes flagged manual), connected accounts ✓ (T5), sessions ✓ (T6), danger zone ✓ (T7), composition + config-gating + router ✓ (T8), reverification wrapper applied to password/email-remove/primary/MFA/unlink/delete ✓, error handling via `isClerkAPIResponseError` ✓ (conventions), tokens-only ✓, single scrolling stack / no inner nav ✓ (T8 + manual smoke).
- **Out of scope honored:** no passkeys/web3/orgs; phone omitted (add mirrored `phone-section.tsx` only if instance enables phone); no backend changes.
- **Known risk to verify during execution:** (1) exact `useReverification` return shape — lock in T1 from the doc and apply uniformly; (2) `isClerkAPIResponseError` import path; (3) instance-enabled OAuth provider enumeration — T8 falls back to a confirmed hardcoded list; (4) QR rendering — plan shows the secret/URI, upgrade only if a QR lib already exists.
