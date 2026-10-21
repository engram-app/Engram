import fs from "node:fs";
import path from "node:path";
import { clerk } from "@clerk/testing/playwright";
import type { Page } from "@playwright/test";

// Shared by the Clerk specs. clerk-auth.spec.ts keeps its own no-retry sign-in
// on purpose (a "No user found" there must surface immediately, see its
// comment); it shares only loadAuthState.

const AUTH_STATE_PATH = path.join(__dirname, ".auth-state.json");

export interface AuthState {
	email: string;
	password: string;
	clerk_user_id: string;
	skipped: boolean;
}

export function loadAuthState(): AuthState {
	if (!fs.existsSync(AUTH_STATE_PATH)) {
		return { email: "", password: "", clerk_user_id: "", skipped: true };
	}
	return JSON.parse(fs.readFileSync(AUTH_STATE_PATH, "utf-8"));
}

/**
 * Sign in through Clerk, riding out cross-replica lag.
 *
 * global-setup's probes confirm the user resolves on ONE Clerk replica, but a
 * later `clerk.signIn` can hit a lagging one and still throw "No user found"
 * (#455). That is eventual consistency, not a logic bug. Clerk's test
 * instance also rate-limits sign-ins shared by every concurrent CI run, and a
 * "Too Many Requests" there is the same kind of transient (e2e-browser on
 * PR #2074, two onboarding-ftux tests). Both retry with backoff on a ~30s
 * budget. Any other error is real and rethrows immediately.
 */
export async function clerkSignIn(page: Page, email: string, landOn = "/"): Promise<void> {
	await page.goto("/sign-in/");

	const deadline = Date.now() + 30_000;
	let backoff = 500;
	let lastErr: unknown;
	let signedIn = false;

	// do/while, not while: a slow `page.goto` above can consume the entire
	// budget, and a `while (Date.now() < deadline)` would then skip the body
	// outright. `lastErr` stays undefined, the throw below is skipped, and this
	// returns having never ATTEMPTED a sign-in. The caller fails 20 seconds
	// later on an unrelated assertion, which is a thoroughly misleading
	// diagnosis. At least one attempt must always run.
	do {
		try {
			await clerk.signIn({ page, emailAddress: email });
			signedIn = true;
		} catch (err) {
			if (!/No user found|Too Many Requests/iu.test(String(err))) {
				throw err;
			}
			lastErr = err;
			await page.waitForTimeout(Math.min(backoff, Math.max(0, deadline - Date.now())));
			backoff = Math.min(backoff * 2, 4000);
		}
	} while (!signedIn && Date.now() < deadline);

	if (!signedIn) {
		throw lastErr ?? new Error(`clerkSignIn: no sign-in attempt succeeded for ${email}`);
	}

	await page.goto(landOn);
}

const CLERK_API = "https://api.clerk.com/v1";

/**
 * A fresh Clerk user with NO onboarding performed. The onboarding specs
 * consume it: finishing the wizard is the thing under test, so each attempt
 * (Playwright retries included) needs its own.
 *
 * No readiness probe here. Clerk's user-list and sign-in-token endpoints can
 * sit on different read replicas (#455), but `clerkSignIn` already rides that
 * out: it retries on "No user found" with backoff.
 */
export async function createUnonboardedUser(prefix = "e2e-browser-pending"): Promise<{ email: string; id: string }> {
	const ts = Date.now();
	const email = `${prefix}-${ts}@test.com`;

	const resp = await fetch(`${CLERK_API}/users`, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${process.env.E2E_CLERK_SECRET_KEY ?? ""}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({
			email_address: [email],
			username: `${prefix.replace(/^e2e-browser-/u, "e2e-")}-${ts}`,
			password: `pw-${ts}-${Math.random().toString(36).slice(2)}`,
			skip_password_checks: true,
		}),
	});

	if (!resp.ok) {
		throw new Error(`Clerk pending-user creation failed: ${resp.status} ${await resp.text()}`);
	}

	const user = await resp.json();
	return { email, id: user.id as string };
}

/**
 * Teardown must not fail the test, but it must not be mute either. A Clerk 429
 * RESOLVES with a non-ok Response rather than throwing, so a bare `.catch()`
 * sees nothing and the user leaks silently into the instance's 100-user cap.
 */
export async function deleteClerkUser(id: string): Promise<void> {
	await fetch(`${CLERK_API}/users/${id}`, {
		method: "DELETE",
		headers: { Authorization: `Bearer ${process.env.E2E_CLERK_SECRET_KEY ?? ""}` },
	})
		.then((resp) => {
			if (!resp.ok) {
				console.warn(`clerk teardown failed for ${id}: ${resp.status}`);
			}
		})
		.catch((err) => console.warn(`clerk teardown errored for ${id}: ${String(err)}`));
}
