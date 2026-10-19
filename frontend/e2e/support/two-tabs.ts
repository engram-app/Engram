import { type BrowserContext, test as base, expect, type Page } from "@playwright/test";
import { createVault, noteUrlRe, PASS, registerAndLogin } from "./api";

// Two signed-in browser contexts (tabs A and B) shared by every test in a
// worker. Registering a user and driving the sign-in form twice cost ~20s of
// each two-tab test's 30s budget. Now the user and both sessions are made once
// per worker; each test gets a fresh vault (isolated tree) and fresh pages.
//
// Each context logs in on its own, not by sharing storageState: refresh tokens
// rotate with reuse detection, so two contexts replaying one cookie would
// revoke the whole family.

interface Vault {
	id: string;
	slug: string;
}

interface Account {
	email: string;
}

interface WorkerFixtures {
	account: Account;
	ctxA: BrowserContext;
	ctxB: BrowserContext;
}
interface TestFixtures {
	token: string;
	vault: Vault;
	pageA: Page;
	pageB: Page;
}

async function signedInContext(
	browser: import("@playwright/test").Browser,
	baseURL: string,
	email: string,
): Promise<BrowserContext> {
	const ctx = await browser.newContext({ baseURL, locale: "en-US" });
	// ctx.request shares the context's cookie jar, so the refresh cookie set
	// here is what the SPA's boot-time /api/auth/refresh presents.
	const res = await ctx.request.post("/api/auth/login", { data: { email, password: PASS } });
	if (!res.ok()) {
		throw new Error(`login failed: ${res.status()} ${await res.text()}`);
	}
	return ctx;
}

export const test = base.extend<TestFixtures, WorkerFixtures>({
	account: [
		// Playwright needs a destructured first argument; `browser` is a no-op dep.
		async ({ browser: _browser }, use, workerInfo) => {
			const baseURL = workerInfo.project.use.baseURL!;
			const email = `e2e-twotab-${Date.now()}-${workerInfo.workerIndex}@test.com`;
			await registerAndLogin(baseURL, email);
			await use({ email });
		},
		{ scope: "worker" },
	],
	ctxA: [
		async ({ browser, account }, use, workerInfo) => {
			const ctx = await signedInContext(browser, workerInfo.project.use.baseURL!, account.email);
			await use(ctx);
			await ctx.close();
		},
		{ scope: "worker" },
	],
	ctxB: [
		async ({ browser, account }, use, workerInfo) => {
			const ctx = await signedInContext(browser, workerInfo.project.use.baseURL!, account.email);
			await use(ctx);
			await ctx.close();
		},
		{ scope: "worker" },
	],
	// Fresh per test: access tokens live 15 min (lib/engram/token.ex), a worker
	// can outlast that. registerAndLogin is idempotent (a 422 re-register is fine).
	token: async ({ account, baseURL }, use) => use(await registerAndLogin(baseURL!, account.email)),
	vault: async ({ token, baseURL }, use) => {
		await use(await createVault(baseURL!, token, `tt-${Date.now()}`));
	},
	pageA: async ({ ctxA }, use) => {
		const page = await ctxA.newPage();
		await use(page);
		await page.close();
	},
	pageB: async ({ ctxB }, use) => {
		const page = await ctxB.newPage();
		await use(page);
		await page.close();
	},
});

// Opens a note in an already signed-in tab at its canonical /v/:slug/:id URL.
// Going through the legacy /note/:id redirect added a hop that, on a loaded
// runner, outran the 10s URL wait. activeVaultId is seeded before any app
// script runs so the vault switcher agrees with the URL from the first render.
export async function openNote(page: Page, vault: Vault, noteId: string): Promise<void> {
	await page.addInitScript((id) => {
		localStorage.setItem("engram.activeVaultId", id);
	}, String(vault.id));
	await page.goto(`/v/${vault.slug}/${noteId}`);
	await expect(page).toHaveURL(noteUrlRe(noteId), { timeout: 10_000 });
}
