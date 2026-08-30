import { type BrowserContext, expect, type Page, test } from "@playwright/test";
import { createVault, noteUrlRe, registerAndLogin, signInForNote, upsertNote } from "./support/api";
import { row } from "./support/tree";

/**
 * Wikilink navigation must NEVER route through the lazy /v/:slug/wiki/* resolver
 * for a target that exists — not even as a transient flash. wikiHref resolves
 * in layers: (1) server-indexed link edges, (2) the sync-manifest client cache,
 * (3) only then the /wiki redirect (kept for deep links + the create
 * affordance). A freshly typed link has no server edge yet, so layer (2) is
 * what keeps the URL off /wiki here.
 *
 * Flash detection: react-router navigates via history.pushState/replaceState
 * (the /wiki route's <Navigate replace> included), so hooking both from an
 * init script records EVERY SPA URL transition — a transient /wiki hop is
 * caught even when the final URL looks right.
 */

declare global {
	interface Window {
		__navLog: string[];
	}
}

async function instrumentHistory(ctx: BrowserContext): Promise<void> {
	await ctx.addInitScript(() => {
		window.__navLog = [];
		for (const method of ["pushState", "replaceState"] as const) {
			const orig = history[method].bind(history);
			history[method] = (data: unknown, unused: string, url?: string | URL | null) => {
				window.__navLog.push(String(url ?? location.href));
				return orig(data, unused, url);
			};
		}
		addEventListener("popstate", () => window.__navLog.push(location.pathname + location.hash));
	});
}

function navLog(page: Page): Promise<string[]> {
	return page.evaluate(() => window.__navLog);
}

async function renameNote(
	baseURL: string,
	token: string,
	vaultId: number,
	oldPath: string,
	newPath: string,
): Promise<void> {
	const res = await fetch(`${baseURL}/api/notes/rename`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
			"X-Vault-Id": String(vaultId),
		},
		body: JSON.stringify({ old_path: oldPath, new_path: newPath }),
	});
	if (!res.ok) {
		throw new Error(`note rename failed: ${res.status} ${await res.text()}`);
	}
}

async function manifestIdFor(
	baseURL: string,
	token: string,
	vaultId: number,
	path: string,
): Promise<string> {
	const res = await fetch(`${baseURL}/api/sync/manifest`, {
		headers: { Authorization: `Bearer ${token}`, "X-Vault-Id": String(vaultId) },
	});
	if (!res.ok) {
		throw new Error(`manifest fetch failed: ${res.status} ${await res.text()}`);
	}
	const { notes } = (await res.json()) as { notes: { id: string; path: string }[] };
	const note = notes.find((n) => n.path === path);
	if (!note) {
		throw new Error(`manifest has no entry for ${path}`);
	}
	return note.id;
}

// Seeds a user + vault, a target note created at one path then RENAMED (the
// user's repro shape — the rename is what leaves any server-side edge state
// behind the manifest), and a source note the browser will type the link into.
async function seedVault(baseURL: string, run: string) {
	const email = `e2e-wikinav-${run}@test.com`;
	const token = await registerAndLogin(baseURL, email);
	const vault = await createVault(baseURL, token, `wikinav-${run}`);
	const targetTitle = `Target-${run}`;
	await upsertNote(baseURL, token, vault.id, `orig-${run}.md`, "# Target seed\n\ntarget body.");
	await renameNote(baseURL, token, vault.id, `orig-${run}.md`, `${targetTitle}.md`);
	const source = await upsertNote(
		baseURL,
		token,
		vault.id,
		`source-${run}.md`,
		"# Source\n\nbody line.",
	);
	const targetId = await manifestIdFor(baseURL, token, vault.id, `${targetTitle}.md`);
	return { email, token, vault, targetTitle, targetId, sourceId: source.id };
}

// Types ` link [[<target>]] tail` at end-of-doc. Trailing text keeps the
// cursor OUTSIDE the wikilink range, so the live-preview widget renders
// immediately (cursor inside the range reveals raw `[[...]]` source instead).
async function typeWikiLink(page: Page, target: string): Promise<void> {
	const editor = page.locator(".cm-content");
	await expect(editor).toContainText("body line.", { timeout: 10_000 });
	await editor.click();
	await page.keyboard.press("Control+End");
	await page.keyboard.insertText(` link [[${target}]] tail`);
}

function editorWikiLink(page: Page, target: string) {
	return page.locator(`.cm-content [data-wiki-link-target="${target}"]`);
}

async function expectNoWikiHops(page: Page, sinceIndex: number): Promise<void> {
	const entries = (await navLog(page)).slice(sinceIndex);
	console.log(`[wiki-nav] history transitions since click: ${JSON.stringify(entries)}`);
	expect(entries.length).toBeGreaterThan(0); // instrumentation actually saw the nav
	for (const url of entries) {
		expect(url, `transient /wiki hop recorded: ${url}`).not.toContain("/wiki/");
	}
	expect(page.url()).not.toContain("/wiki/");
}

test.describe("wikilink navigation never routes through /wiki for existing notes", () => {
	test("editor live-preview click on a freshly typed link goes straight to the id route", async ({
		browser,
		baseURL,
	}) => {
		const run = `ed-${Date.now()}`;
		const { email, vault, targetTitle, targetId, sourceId } = await seedVault(baseURL!, run);

		const ctx = await browser.newContext();
		await instrumentHistory(ctx);
		const page = await ctx.newPage();
		await signInForNote(page, email, vault.id, sourceId);

		await typeWikiLink(page, targetTitle);
		const link = editorWikiLink(page, targetTitle);
		await expect(link).toBeVisible();

		// Click promptly — no settling wait. The freshly typed link has no
		// server-indexed edge in the client's note query yet; resolution must
		// come from the manifest layer, not the /wiki fallback.
		const before = (await navLog(page)).length;
		console.log(`[wiki-nav] editor: clicking [[${targetTitle}]] -> expect /${targetId}`);
		await link.click();

		await expect(page).toHaveURL(noteUrlRe(targetId), { timeout: 10_000 });
		await expectNoWikiHops(page, before);
		await expect(page.locator(".cm-content")).toContainText("target body.", { timeout: 10_000 });

		await ctx.close();
	});

	test("reading-mode click on a freshly typed link goes straight to the id route", async ({
		browser,
		baseURL,
	}) => {
		const run = `rd-${Date.now()}`;
		const { email, vault, targetTitle, targetId, sourceId } = await seedVault(baseURL!, run);

		const ctx = await browser.newContext();
		await instrumentHistory(ctx);
		const page = await ctx.newPage();
		await signInForNote(page, email, vault.id, sourceId);

		await typeWikiLink(page, targetTitle);
		await page.getByRole("button", { name: "Reading view" }).click();

		const link = page.getByRole("link", { name: targetTitle });
		await expect(link).toBeVisible();
		// The href itself must already be the id route — the /wiki fallback
		// would be a flash risk even before any click.
		const href = await link.getAttribute("href");
		console.log(`[wiki-nav] reading: rendered href=${href}`);
		expect(href).not.toContain("/wiki/");
		expect(href).toContain(String(targetId));

		const before = (await navLog(page)).length;
		await link.click();

		await expect(page).toHaveURL(noteUrlRe(targetId), { timeout: 10_000 });
		await expectNoWikiHops(page, before);

		await ctx.close();
	});

	test("nonexistent target lands on /wiki with the create affordance, and Create opens the new note", async ({
		browser,
		baseURL,
	}) => {
		const run = `nx-${Date.now()}`;
		const { email, vault, sourceId } = await seedVault(baseURL!, run);
		const missing = `NoSuchNote-${run}-${Math.random().toString(36).slice(2, 10)}`;

		const ctx = await browser.newContext();
		await instrumentHistory(ctx);
		const page = await ctx.newPage();
		await signInForNote(page, email, vault.id, sourceId);

		await typeWikiLink(page, missing);
		const link = editorWikiLink(page, missing);
		await expect(link).toBeVisible();
		console.log(`[wiki-nav] nonexistent: clicking [[${missing}]] -> expect /wiki create page`);
		await link.click();

		// A truly nonexistent target is exactly what the /wiki resolver is FOR.
		await expect(page).toHaveURL(new RegExp(`/wiki/${missing}`, "u"), { timeout: 10_000 });
		await expect(
			page.getByRole("heading", { name: `"${missing}" doesn't exist yet.` }),
		).toBeVisible();

		await page.getByRole("button", { name: `Create "${missing}"` }).click();

		// useCreateNote mints a uuid7 note id and navigates to its id route.
		await expect(page).toHaveURL(/\/[0-9a-f]{8}-[0-9a-f-]{27}(?:[?#]|$)/u, { timeout: 10_000 });
		expect(page.url()).not.toContain("/wiki/");
		await expect(row(page, missing)).toBeVisible({ timeout: 10_000 });

		await ctx.close();
	});
});
