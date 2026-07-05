import { expect, test } from "@playwright/test";
import { createVault, registerAndLogin, signInForNote, upsertNote } from "./support/api";

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
