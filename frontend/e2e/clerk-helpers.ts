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
