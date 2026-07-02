import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { clerkSetup } from "@clerk/testing/playwright";
import { cleanupTestUsers } from "./db-cleanup";

const AUTH_STATE_PATH = path.join(__dirname, ".auth-state.json");
const CLERK_API = "https://api.clerk.com/v1";

const CLERK_BACKEND_PORT = process.env.PW_CLERK_BACKEND_PORT ?? "4001";
const CLERK_API_BASE = `http://localhost:${CLERK_BACKEND_PORT}/api`;

async function preCompleteOnboarding(userId: string, secretKey: string): Promise<void> {
	// Mint a short-lived Clerk session token, use it to provision the Engram
	// user record (POST /api-keys triggers find_or_create_by_clerk_id), then
	// mark onboarding complete so OnboardingGate stops redirecting tests away
	// from the dashboard.
	const sessionResp = await fetch(`${CLERK_API}/sessions`, {
		method: "POST",
		headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" },
		body: JSON.stringify({ user_id: userId }),
	});
	if (!sessionResp.ok) {
		throw new Error(
			`Clerk create session failed: ${sessionResp.status} ${await sessionResp.text()}`,
		);
	}
	const sessionId = (await sessionResp.json()).id as string;

	const tokenResp = await fetch(`${CLERK_API}/sessions/${sessionId}/tokens`, {
		method: "POST",
		headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" },
	});
	if (!tokenResp.ok) {
		throw new Error(`Clerk mint token failed: ${tokenResp.status} ${await tokenResp.text()}`);
	}
	const jwt = (await tokenResp.json()).jwt as string;

	// Provision the user in Engram's DB via /api-keys (any authenticated
	// call would do; this one keeps a parity with the Python provider).
	const keyResp = await fetch(`${CLERK_API_BASE}/api-keys`, {
		method: "POST",
		headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
		body: JSON.stringify({ name: "e2e-browser-key" }),
	});
	if (!keyResp.ok) {
		throw new Error(`Engram api-keys POST failed: ${keyResp.status} ${await keyResp.text()}`);
	}

	const profResp = await fetch(`${CLERK_API_BASE}/onboarding/profile`, {
		method: "PATCH",
		headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
		body: JSON.stringify({ uses_obsidian: true, tools: ["claude"] }),
	});
	if (!profResp.ok) {
		throw new Error(
			`Engram onboarding profile PATCH failed: ${profResp.status} ${await profResp.text()}`,
		);
	}

	// Suppress the checklist tour row + CreateFirstVaultModal — they'd
	// intercept every click on the dashboard, breaking sign-out / theme /
	// mobile / note tests. The FTUX modal-specific tests already use
	// idempotent "skip if absent" checks for these modals, so seeding here
	// doesn't regress that coverage.
	const actionResp = await fetch(`${CLERK_API_BASE}/onboarding/actions`, {
		method: "POST",
		headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
		body: JSON.stringify({ action: "dismissed:tour" }),
	});
	if (!actionResp.ok) {
		throw new Error(
			`Onboarding action POST failed: ${actionResp.status} ${await actionResp.text()}`,
		);
	}

	const vaultResp = await fetch(`${CLERK_API_BASE}/vaults`, {
		method: "POST",
		headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
		body: JSON.stringify({ name: "E2E Default Vault" }),
	});
	if (!vaultResp.ok) {
		throw new Error(`Vault POST failed: ${vaultResp.status} ${await vaultResp.text()}`);
	}

	console.log(`Pre-completed onboarding for Clerk user ${userId}`);
}

const SIGN_IN_READY_MAX_WAIT_MS = 60_000;
const SIGN_IN_READY_INITIAL_BACKOFF_MS = 500;
const SIGN_IN_READY_MAX_BACKOFF_MS = 8000;

/**
 * Block until Clerk's POST /sign_in_tokens stops 404'ing the given user.
 *
 * Same eventual-consistency story as the Python helper's _wait_until_session_ready
 * (POST /sessions), but for the endpoint @clerk/testing's clerk.signIn uses
 * under the hood. Both endpoints share Clerk's user-lookup propagation lag;
 * probing each one separately means we don't assume they're backed by the
 * same read replica.
 *
 * Throws on non-404 errors or when the wall-clock budget is exhausted.
 */
async function waitUntilSignInReady(userId: string, secretKey: string): Promise<void> {
	const headers = {
		Authorization: `Bearer ${secretKey}`,
		"Content-Type": "application/json",
	};
	const deadline = Date.now() + SIGN_IN_READY_MAX_WAIT_MS;
	let backoff = SIGN_IN_READY_INITIAL_BACKOFF_MS;
	let attempt = 0;
	// ±20% jitter avoids thundering-herd on Clerk when multiple e2e jobs
	// provision users in parallel during a degraded window.
	const jittered = (ms: number) => ms + ms * (Math.random() * 0.4 - 0.2);

	while (true) {
		attempt++;
		const resp = await fetch(`${CLERK_API}/sign_in_tokens`, {
			method: "POST",
			headers,
			body: JSON.stringify({ user_id: userId, expires_in_seconds: 60 }),
		});
		if (resp.ok) {
			console.log(
				`Clerk sign-in-tokens probe succeeded for ${userId} on attempt ${attempt} (token discarded)`,
			);
			return;
		}
		const body = await resp.text();
		let is404NotFound = false;
		if (resp.status === 404) {
			try {
				const parsed = JSON.parse(body) as { errors?: Array<{ code?: string }> };
				is404NotFound = (parsed.errors ?? []).some((e) => e.code === "resource_not_found");
			} catch {
				// Non-JSON 404 — fall through to the non-propagation error path.
			}
		}
		if (!is404NotFound) {
			throw new Error(
				`Clerk sign-in-tokens probe failed (non-404 or non-propagation): ${resp.status} ${body}`,
			);
		}
		const remaining = deadline - Date.now();
		if (remaining <= 0) {
			throw new Error(
				`Clerk POST /sign_in_tokens still 404 for user ${userId} after ${SIGN_IN_READY_MAX_WAIT_MS}ms (${attempt} attempts)`,
			);
		}
		const sleepFor = Math.min(jittered(backoff), remaining);
		console.warn(
			`Clerk sign-in-tokens probe 404 for ${userId} (attempt ${attempt}, sleeping ${Math.round(sleepFor)}ms, ${remaining}ms remaining)`,
		);
		await new Promise((r) => setTimeout(r, sleepFor));
		backoff = Math.min(backoff * 2, SIGN_IN_READY_MAX_BACKOFF_MS);
	}
}

/**
 * Block until Clerk's GET /users?email_address=<email> returns the user.
 *
 * Mirror of waitUntilSignInReady but for the OTHER endpoint @clerk/testing
 * hits first: the email→user_id resolution. clerk.signIn({emailAddress})
 * calls clerkClient.users.getUserList({emailAddress:[email]}) before any
 * sign-in token is created, and that lookup returns an empty 200 (not 404)
 * while the email index lags behind the create. Without this probe we
 * still hit "No user found with email" deep in test code after
 * waitUntilSignInReady succeeded — same replica-divergence pattern that
 * motivated splitting the probes in #415.
 */
async function waitUntilEmailResolvable(
	email: string,
	expectedUserId: string,
	secretKey: string,
): Promise<void> {
	const headers = { Authorization: `Bearer ${secretKey}` };
	const deadline = Date.now() + SIGN_IN_READY_MAX_WAIT_MS;
	let backoff = SIGN_IN_READY_INITIAL_BACKOFF_MS;
	let attempt = 0;
	const jittered = (ms: number) => ms + ms * (Math.random() * 0.4 - 0.2);

	while (true) {
		attempt++;
		const resp = await fetch(`${CLERK_API}/users?email_address=${encodeURIComponent(email)}`, {
			headers,
		});
		if (!resp.ok) {
			throw new Error(
				`Clerk email-lookup probe failed (non-2xx): ${resp.status} ${await resp.text()}`,
			);
		}
		const users = (await resp.json()) as Array<{ id?: string }>;
		if (Array.isArray(users) && users.some((u) => u.id === expectedUserId)) {
			console.log(`Clerk email-lookup probe succeeded for ${email} on attempt ${attempt}`);
			return;
		}
		// 200 + empty/wrong-user = email index still lagging; back off + retry.
		const remaining = deadline - Date.now();
		if (remaining <= 0) {
			throw new Error(
				`Clerk GET /users?email_address still did not return user ${expectedUserId} after ${SIGN_IN_READY_MAX_WAIT_MS}ms (${attempt} attempts)`,
			);
		}
		const sleepFor = Math.min(jittered(backoff), remaining);
		console.warn(
			`Clerk email-lookup probe empty for ${email} (attempt ${attempt}, sleeping ${Math.round(sleepFor)}ms, ${remaining}ms remaining)`,
		);
		await new Promise((r) => setTimeout(r, sleepFor));
		backoff = Math.min(backoff * 2, SIGN_IN_READY_MAX_BACKOFF_MS);
	}
}

// Only clean up browser-e2e's own users — other prefixes belong to the
// Python E2E job which may be running in parallel on the same Clerk account.
const E2E_PREFIXES = ["e2e-browser-"];

async function cleanupOrphanedClerkUsers(secretKey: string) {
	const headers = { Authorization: `Bearer ${secretKey}` };
	let deleted = 0;

	for (let offset = 0; ; offset += 100) {
		const resp = await fetch(`${CLERK_API}/users?limit=100&offset=${offset}&order_by=created_at`, {
			headers,
		});
		if (!resp.ok) {
			break;
		}
		const users = await resp.json();
		if (users.length === 0) {
			break;
		}

		for (const user of users) {
			const emails: string[] =
				user.email_addresses?.map((ea: { email_address: string }) => ea.email_address) ?? [];
			if (emails.some((e: string) => E2E_PREFIXES.some((p) => e.startsWith(p)))) {
				const del = await fetch(`${CLERK_API}/users/${user.id}`, { method: "DELETE", headers });
				if (del.ok) {
					deleted++;
				}
			}
		}
		if (users.length < 100) {
			break;
		}
	}

	if (deleted) {
		console.log(`Cleaned up ${deleted} orphaned Clerk test user(s)`);
	}
}

export default async function globalSetup() {
	// Clean up stale test users from previous runs (in case teardown didn't run)
	await cleanupTestUsers("setup");

	const secretKey = process.env.E2E_CLERK_SECRET_KEY;
	if (!secretKey) {
		console.log("E2E_CLERK_SECRET_KEY not set — Clerk browser tests will be skipped");
		fs.writeFileSync(AUTH_STATE_PATH, JSON.stringify({ skipped: true }));
		return;
	}

	// Set CLERK_SECRET_KEY for @clerk/testing (it reads this env var)
	process.env.CLERK_SECRET_KEY = secretKey;
	await clerkSetup();

	// Clean up orphaned Clerk users from previous failed runs
	await cleanupOrphanedClerkUsers(secretKey);

	const ts = Date.now();
	const email = `e2e-browser-${ts}@test.com`;
	const password = crypto.randomBytes(12).toString("base64url");

	const resp = await fetch(`${CLERK_API}/users`, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${secretKey}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({
			email_address: [email],
			username: `e2e-browser-${ts}`,
			password,
			skip_password_checks: true,
		}),
	});

	if (!resp.ok) {
		const body = await resp.text();
		throw new Error(`Clerk user creation failed: ${resp.status} ${body}`);
	}

	const user = await resp.json();
	console.log(`Clerk test user created: ${email} (${user.id})`);

	// Stamp the state file IMMEDIATELY so globalTeardown can clean up the
	// Clerk user even if a subsequent setup step throws. Previously the file
	// wasn't written until AFTER waitUntilSignInReady + preCompleteOnboarding,
	// which meant any flake in those probes leaked a user into Clerk's dev
	// instance — the main cause of the 100-user-cap hits we've been seeing.
	fs.writeFileSync(
		AUTH_STATE_PATH,
		JSON.stringify({
			email,
			password,
			clerk_user_id: user.id,
			skipped: false,
		}),
	);

	// Block until BOTH endpoints @clerk/testing's signIn helper uses can see
	// this user. Splitting the probe in two because Clerk's user-list-by-email
	// lookup (called FIRST by signIn) and sign-in-tokens (called second) can
	// sit on different read replicas — the existing tokens probe alone was
	// insufficient and we still hit "No user found with email" deep in test
	// code (issue #193 recurrence post-#415). Concentrates the wait into one
	// site so test code doesn't need retries.
	await waitUntilSignInReady(user.id, secretKey);
	await waitUntilEmailResolvable(email, user.id, secretKey);

	// Pre-complete onboarding for the Clerk test user against the clerk backend.
	// RequireOnboarding gates /api/* with 403 `onboarding_required` until the
	// user has a profile. uses_obsidian=true short-circuits the vault step too.
	await preCompleteOnboarding(user.id, secretKey);
}
