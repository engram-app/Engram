import { expect, test } from "@playwright/test";
import { createVault, registerAndLogin, signInForNote, upsertNote } from "./support/api";
import { commitRename, openContextMenu, pickAction, row, treeRoot } from "./support/tree";

test.describe("web tree ops sync (web to web)", () => {
	test("smoke: signed-in tab shows the folder tree with a seeded note", async ({
		browser,
		baseURL,
	}) => {
		const email = `e2e-tree-smoke-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treesmoke-${Date.now()}`);
		const { id: noteId } = await upsertNote(baseURL!, token, vault.id, "alpha.md", "body only\n");

		const ctx = await browser.newContext();
		const page = await ctx.newPage();
		await signInForNote(page, email, vault.id, noteId);

		await expect(treeRoot(page)).toBeVisible({ timeout: 10_000 });
		await expect(row(page, "alpha")).toBeVisible({ timeout: 10_000 });

		await ctx.close();
	});

	test("rename note propagates to a second tab", async ({ browser, baseURL }) => {
		const email = `e2e-tree-rn-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treern-${Date.now()}`);
		// Body only, no heading: tree label is the filename without extension.
		const { id: noteId } = await upsertNote(
			baseURL!,
			token,
			vault.id,
			"rename-me.md",
			"just body\n",
		);

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		await signInForNote(pageA, email, vault.id, noteId);
		await signInForNote(pageB, email, vault.id, noteId);

		await expect(row(pageA, "rename-me")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "rename-me")).toBeVisible({ timeout: 10_000 });

		// Tab A: rename via the real context-menu + inline input.
		await openContextMenu(pageA, "rename-me");
		await pickAction(pageA, "Rename");
		await commitRename(pageA, "renamed-note");

		// Origin correctness: tab A tree shows the new name, old name gone.
		await expect(row(pageA, "renamed-note")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageA, "rename-me")).toHaveCount(0);

		// Convergence: tab B tree shows the new name, old name gone.
		await expect(row(pageB, "renamed-note")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "rename-me")).toHaveCount(0);

		await ctxA.close();
		await ctxB.close();
	});
});
