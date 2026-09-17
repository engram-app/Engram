import fs from "node:fs";
import path from "node:path";
import { clerk } from "@clerk/testing/playwright";
import type { Page } from "@playwright/test";

// Promoted out of clerk-auth.spec.ts / onboarding-ftux.spec.ts, which both
// carry a copy and both say to extract "if a third Clerk spec lands". One has.
// Those two still hold their copies — migrating them is mechanical but would
// mean editing passing specs inside an unrelated change.

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
 * (#455). That is eventual consistency, not a logic bug, so it is retried on a
 * ~20s budget. Any other error is real and rethrows immediately.
 */
export async function clerkSignIn(page: Page, email: string, landOn = "/"): Promise<void> {
	await page.goto("/sign-in/");

	const deadline = Date.now() + 20_000;
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
			if (!/No user found/iu.test(String(err))) {
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
