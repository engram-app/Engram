import { expect, type Page, test } from "@playwright/test";

/**
 * #277 — Two-session live-update behavior for the web SPA note editor.
 *
 * Tests bootstrap a user + vault + note via the REST API, open the note
 * in a browser, then assert that live changes propagate without a reload.
 *
 * The editor binds CodeMirror 6 to a Yjs Y.Text via yCollab. Remote changes
 * from other CRDT clients converge through the Phoenix CRDT channel with no
 * client-side 3-way merge and no ConflictBar. A REST upsert from an external
 * client (plugin push, MCP write) is broadcast as an authoritative
 * note_changed event that re-seeds the Y.Doc; true concurrent in-browser edits
 * converge via the CRDT protocol.
 */

const PASS = "E2eTestPass!99";

async function registerAndLogin(baseURL: string, email: string): Promise<string> {
	const reg = await fetch(`${baseURL}/api/auth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password: PASS }),
	});
	if (!reg.ok && reg.status !== 422) {
		throw new Error(`register failed: ${reg.status} ${await reg.text()}`);
	}

	const login = await fetch(`${baseURL}/api/auth/login`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password: PASS }),
	});
	if (!login.ok) {
		throw new Error(`login failed: ${login.status} ${await login.text()}`);
	}
	const { access_token } = (await login.json()) as { access_token: string };

	const auth = { "Content-Type": "application/json", Authorization: `Bearer ${access_token}` };
	const prof = await fetch(`${baseURL}/api/onboarding/profile`, {
		method: "PATCH",
		headers: auth,
		body: JSON.stringify({ uses_obsidian: true, tools: ["claude"] }),
	});
	if (!prof.ok) {
		throw new Error(`onboarding PATCH failed: ${prof.status} ${await prof.text()}`);
	}
	// Vault is created later by the spec (createVault helper). Just suppress
	// the checklist tour row so the dashboard doesn't intercept editor clicks.
	const act = await fetch(`${baseURL}/api/onboarding/actions`, {
		method: "POST",
		headers: auth,
		body: JSON.stringify({ action: "dismissed:tour" }),
	});
	if (!act.ok) {
		throw new Error(`onboarding action POST failed: ${act.status} ${await act.text()}`);
	}

	return access_token;
}

interface Vault {
	id: number;
	name: string;
}

async function createVault(baseURL: string, token: string, name: string): Promise<Vault> {
	const res = await fetch(`${baseURL}/api/vaults`, {
		method: "POST",
		headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
		body: JSON.stringify({ name }),
	});
	if (!res.ok) {
		throw new Error(`vault create failed: ${res.status} ${await res.text()}`);
	}
	const { vault } = (await res.json()) as { vault: Vault };
	return vault;
}

async function upsertNote(
	baseURL: string,
	token: string,
	vaultId: number,
	path: string,
	content: string,
	version?: number,
): Promise<{ id: number }> {
	const res = await fetch(`${baseURL}/api/notes`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
			"X-Vault-Id": String(vaultId),
		},
		body: JSON.stringify({ path, content, mtime: Date.now() / 1000, version }),
	});
	if (!res.ok) {
		throw new Error(`note upsert failed: ${res.status} ${await res.text()}`);
	}
	const { note } = (await res.json()) as { note: { id: number } };
	return { id: note.id };
}

/**
 * Sign in by going to the target note URL first — AuthGuard redirects to
 * `/sign-in?return_to=...` and bounces back after sign-in completes.
 * Seed `engram.activeVaultId` on the sign-in page so it survives the post-
 * sign-in route change (same origin, same storage).
 */
async function signInForNote(
	page: Page,
	email: string,
	vaultId: number,
	noteId: number,
): Promise<void> {
	// Hitting /note/:id unauth -> AuthGuard redirects to /sign-in?return_to=...
	await page.goto(`/note/${noteId}`);
	await expect(page).toHaveURL(/\/sign-in/u, { timeout: 10_000 });

	// Seed active vault before sign-in completes so the post-redirect render
	// already has it (vault-switcher's auto-select wouldn't pick our new vault
	// before NotePage's first query fires).
	await page.evaluate((id) => {
		localStorage.setItem("engram.activeVaultId", String(id));
	}, vaultId);

	await page.getByLabel("Email").fill(email);
	await page.getByLabel("Password", { exact: true }).fill(PASS);
	await page.getByRole("button", { name: /sign in/iu }).click();

	await expect(page).toHaveURL(new RegExp(`/note/${noteId}`), { timeout: 10_000 });
}

test.describe("SPA viewer live-update (#277)", () => {
	test("viewer re-renders when a remote client upserts the open note", async ({
		browser,
		baseURL,
	}) => {
		const email = `e2e-live-view-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `liveview-${Date.now()}`);
		const path = "live-view.md";
		const { id: noteId } = await upsertNote(
			baseURL!,
			token,
			vault.id,
			path,
			"# Initial\n\nFirst body.",
		);

		const ctx = await browser.newContext();
		const page = await ctx.newPage();
		await signInForNote(page, email, vault.id, noteId);

		// The note opens in the editor (plain markdown source) by default.
		const editor = page.locator(".cm-content");
		await expect(editor).toContainText("First body.", { timeout: 10_000 });

		// Remote upsert (simulates plugin push / MCP write / other web tab Save).
		await upsertNote(baseURL!, token, vault.id, path, "# Initial\n\nSecond body remote.");

		// The channel propagates the change into the open editor — no reload.
		await expect(editor).toContainText("Second body remote.", { timeout: 5000 });
		await expect(editor).not.toContainText("First body.");

		await ctx.close();
	});

	test("concurrent edits in two tabs converge in both editors (CRDT, no conflict bar)", async ({
		browser,
		baseURL,
	}) => {
		const email = `e2e-live-crdt-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `livecrdt-${Date.now()}`);
		const path = "live-crdt.md";
		const { id: noteId } = await upsertNote(
			baseURL!,
			token,
			vault.id,
			path,
			"# Initial\n\nbase line.",
		);

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();

		await signInForNote(pageA, email, vault.id, noteId);
		await signInForNote(pageB, email, vault.id, noteId);

		const edA = pageA.locator(".cm-content");
		const edB = pageB.locator(".cm-content");

		await expect(edA).toContainText("base line.", { timeout: 10_000 });
		await expect(edB).toContainText("base line.", { timeout: 10_000 });

		// Distinct concurrent edits, one per tab (appending at end-of-doc means
		// the two inserts land at the same anchor as concurrent CRDT ops; the
		// CRDT orders them deterministically by client id so both substrings are
		// always present regardless of order).
		await edA.click();
		await pageA.keyboard.press("Control+End");
		await pageA.keyboard.type(" AAA-from-tab-a");

		await edB.click();
		await pageB.keyboard.press("Control+End");
		await pageB.keyboard.type(" BBB-from-tab-b");

		// Both edits must converge in BOTH editors via the CRDT channel.
		// If either assertion times out here, that is a real CRDT convergence bug
		// — do NOT weaken the timeout or assertion to make the test pass.
		for (const ed of [edA, edB]) {
			await expect(ed).toContainText("AAA-from-tab-a", { timeout: 10_000 });
			await expect(ed).toContainText("BBB-from-tab-b", { timeout: 10_000 });
		}

		// The ConflictBar UI was intentionally removed with the CRDT migration.
		// Neither tab should ever render it.
		await expect(pageA.getByTestId("conflict-bar")).toHaveCount(0);
		await expect(pageB.getByTestId("conflict-bar")).toHaveCount(0);

		await ctxA.close();
		await ctxB.close();
	});
});
