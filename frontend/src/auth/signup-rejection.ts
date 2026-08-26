// Bridges the gap between Clerk's client-side sign-up and the server-side
// multi-account block. When a sign-up trips the block, the backend deletes the
// Clerk user ~1s after creation, orphaning the session and bouncing the app to
// /sign-in with no explanation. We remember the just-created Clerk user id here
// so the sign-in page can ask the backend why, and show a real message.

import { getApiBase, joinApiUrl } from "../api/base";
import { isMember } from "../lib/is-member";

const KEY = "engram:pending-signup";
const WINDOW_MS = 2 * 60 * 1000;

export type SignupRejectionReason = "duplicate_identity";

const REJECTION_REASONS: readonly SignupRejectionReason[] = ["duplicate_identity"];

const isSignupRejectionReason = (v: unknown): v is SignupRejectionReason =>
	isMember(REJECTION_REASONS, v);

export function rememberSignupUser(clerkUserId: string): void {
	try {
		sessionStorage.setItem(KEY, JSON.stringify({ id: clerkUserId, ts: Date.now() }));
	} catch {
		// sessionStorage unavailable (private mode / SSR) — non-fatal.
	}
}

// Returns the recent pending sign-up id and clears it, so the lookup runs at
// most once per bounce. Stale entries (older than the window) are dropped.
export function takePendingSignupUser(): string | null {
	try {
		const raw = sessionStorage.getItem(KEY);
		if (!raw) {
			return null;
		}
		sessionStorage.removeItem(KEY);
		const parsed: unknown = JSON.parse(raw);
		if (typeof parsed !== "object" || parsed === null || !("id" in parsed && "ts" in parsed)) {
			return null;
		}
		const { id, ts } = parsed;
		if (typeof id !== "string" || typeof ts !== "number" || Date.now() - ts > WINDOW_MS) {
			return null;
		}
		return id;
	} catch {
		return null;
	}
}

// Public, unauthenticated endpoint — the session is gone by now, so this is a
// plain fetch with no auth coupling. 404 means "not rejected".
export async function fetchSignupRejection(
	clerkUserId: string,
): Promise<SignupRejectionReason | null> {
	try {
		const res = await fetch(
			joinApiUrl(
				getApiBase(),
				`/api/auth/signup-rejection?clerk_id=${encodeURIComponent(clerkUserId)}`,
			),
		);
		if (!res.ok) {
			return null;
		}
		const body: unknown = await res.json();
		if (typeof body !== "object" || body === null || !("reason" in body)) {
			return null;
		}
		return isSignupRejectionReason(body.reason) ? body.reason : null;
	} catch (err) {
		// A transport failure (network/DNS/CORS) is distinct from a 404 "not
		// rejected" — we still degrade to null for UX, but surface it for debugging.
		console.warn("signup-rejection lookup failed", err);
		return null;
	}
}
