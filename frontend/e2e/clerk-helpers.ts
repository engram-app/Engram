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

	while (Date.now() < deadline) {
		try {
			await clerk.signIn({ page, emailAddress: email });
			lastErr = undefined;
			break;
		} catch (err) {
			if (!/No user found/iu.test(String(err))) {
				throw err;
			}
			lastErr = err;
			await page.waitForTimeout(Math.min(backoff, Math.max(0, deadline - Date.now())));
			backoff = Math.min(backoff * 2, 4000);
		}
	}

	if (lastErr) {
		throw lastErr;
	}

	await page.goto(landOn);
}
