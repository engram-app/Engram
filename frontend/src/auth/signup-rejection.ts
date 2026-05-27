// Bridges the gap between Clerk's client-side sign-up and the server-side
// multi-account block. When a sign-up trips the block, the backend deletes the
// Clerk user ~1s after creation, orphaning the session and bouncing the app to
// /sign-in with no explanation. We remember the just-created Clerk user id here
// so the sign-in page can ask the backend why, and show a real message.

const KEY = 'engram:pending-signup'
const WINDOW_MS = 2 * 60 * 1000

export type SignupRejectionReason = 'duplicate_identity'

export function rememberSignupUser(clerkUserId: string): void {
  try {
    sessionStorage.setItem(KEY, JSON.stringify({ id: clerkUserId, ts: Date.now() }))
  } catch {
    // sessionStorage unavailable (private mode / SSR) — non-fatal.
  }
}

// Returns the recent pending sign-up id and clears it, so the lookup runs at
// most once per bounce. Stale entries (older than the window) are dropped.
export function takePendingSignupUser(): string | null {
  try {
    const raw = sessionStorage.getItem(KEY)
    if (!raw) return null
    sessionStorage.removeItem(KEY)
    const { id, ts } = JSON.parse(raw) as { id?: string; ts?: number }
    if (!id || !ts || Date.now() - ts > WINDOW_MS) return null
    return id
  } catch {
    return null
  }
}

// Public, unauthenticated endpoint — the session is gone by now, so this is a
// plain fetch with no auth coupling. 404 means "not rejected".
export async function fetchSignupRejection(
  clerkUserId: string,
): Promise<SignupRejectionReason | null> {
  try {
    const res = await fetch(`/api/auth/signup-rejection?clerk_id=${encodeURIComponent(clerkUserId)}`)
    if (!res.ok) return null
    const body = (await res.json()) as { reason?: SignupRejectionReason | null }
    return body.reason ?? null
  } catch (err) {
    // A transport failure (network/DNS/CORS) is distinct from a 404 "not
    // rejected" — we still degrade to null for UX, but surface it for debugging.
    console.warn('signup-rejection lookup failed', err)
    return null
  }
}
