import { expect, test } from "@playwright/test";
import {
	createFolder,
	createVault,
	registerAndLogin,
	signInForNote,
	upsertNote,
} from "./support/api";
import {
	commitRename,
	confirmDelete,
	expandFolder,
	openContextMenu,
	pickAction,
	pickMoveTarget,
	row,
	treeRoot,
} from "./support/tree";

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

		// Content sync must survive the rename. Both tabs are anchored on the note
		// (id stable across rename), so the editor stays bound. Edit in tab A and
		// confirm it converges in tab B: a regression here means the rename broke
		// the note's live content channel.
		const edA = pageA.locator(".cm-content");
		const edB = pageB.locator(".cm-content");
		await edA.click();
		await pageA.keyboard.press("Control+End");
		await pageA.keyboard.type(" EDIT-AFTER-RENAME");
		await expect(edB).toContainText("EDIT-AFTER-RENAME", { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});

	test("delete note propagates to a second tab", async ({ browser, baseURL }) => {
		const email = `e2e-tree-del-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treedel-${Date.now()}`);
		const { id: keepId } = await upsertNote(baseURL!, token, vault.id, "keep.md", "keep body\n");
		await upsertNote(baseURL!, token, vault.id, "trash.md", "trash body\n");

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		// Anchor both tabs on the note that survives, so neither navigates to a
		// deleted route.
		await signInForNote(pageA, email, vault.id, keepId);
		await signInForNote(pageB, email, vault.id, keepId);

		await expect(row(pageA, "trash")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "trash")).toBeVisible({ timeout: 10_000 });

		await openContextMenu(pageA, "trash");
		await pickAction(pageA, "Delete");
		await confirmDelete(pageA);

		await expect(row(pageA, "trash")).toHaveCount(0, { timeout: 10_000 });
		await expect(row(pageB, "trash")).toHaveCount(0, { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});

	test("move note propagates to a second tab", async ({ browser, baseURL }) => {
		const email = `e2e-tree-mv-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treemv-${Date.now()}`);
		await createFolder(baseURL!, token, vault.id, "Source");
		await createFolder(baseURL!, token, vault.id, "Dest");
		const { id: noteId } = await upsertNote(
			baseURL!,
			token,
			vault.id,
			"Source/mover.md",
			"movable body\n",
		);

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		await signInForNote(pageA, email, vault.id, noteId);
		await signInForNote(pageB, email, vault.id, noteId);

		// Reveal children in both tabs.
		await expandFolder(pageA, "Source");
		await expandFolder(pageA, "Dest");
		await expandFolder(pageB, "Source");
		await expandFolder(pageB, "Dest");

		await expect(row(pageA, "mover")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "mover")).toBeVisible({ timeout: 10_000 });

		// Move mover from Source to Dest via the Move dialog.
		await openContextMenu(pageA, "mover");
		await pickAction(pageA, "Move to…");
		await pickMoveTarget(pageA, "Dest");

		// Convergence: after the move, "mover" lives under Dest in tab B.
		// The note row still reads "mover" (title unchanged); assert it is now a
		// descendant of the Dest folder row group. Because the tree is flat-
		// virtualized we assert on presence plus that Source no longer lists it.
		// Re-expand in case invalidation collapsed nothing but refetched lists.
		await expandFolder(pageB, "Dest");
		await expect(row(pageB, "mover")).toBeVisible({ timeout: 10_000 });

		// Old folder must no longer contain the note. Collapse Dest so the only
		// visible "mover" row would be under Source, then assert it is gone when
		// Source is expanded and Dest collapsed.
		await row(pageB, "Dest").click(); // collapse Dest
		await expect(row(pageB, "Dest")).toHaveAttribute("aria-expanded", "false");
		await expandFolder(pageB, "Source");
		await expect(row(pageB, "mover")).toHaveCount(0, { timeout: 10_000 });

		// Content sync must survive the move. Both tabs are anchored on the note
		// (/note/:id, id stable across the move), so the editor stays bound.
		// Edit in tab A and confirm it converges in tab B: a regression here means
		// the move broke the note's live content channel.
		const edA = pageA.locator(".cm-content");
		const edB = pageB.locator(".cm-content");
		await edA.click();
		await pageA.keyboard.press("Control+End");
		await pageA.keyboard.type(" EDIT-AFTER-MOVE");
		await expect(edB).toContainText("EDIT-AFTER-MOVE", { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});

	test("rename folder propagates to a second tab, child re-paths", async ({ browser, baseURL }) => {
		const email = `e2e-tree-rnf-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treernf-${Date.now()}`);
		await createFolder(baseURL!, token, vault.id, "OldName");
		const { id: childId } = await upsertNote(
			baseURL!,
			token,
			vault.id,
			"OldName/child.md",
			"child body\n",
		);

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		await signInForNote(pageA, email, vault.id, childId);
		await signInForNote(pageB, email, vault.id, childId);

		await expect(row(pageA, "OldName")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "OldName")).toBeVisible({ timeout: 10_000 });

		await openContextMenu(pageA, "OldName");
		await pickAction(pageA, "Rename");
		await commitRename(pageA, "NewName");

		// Origin: folder node renamed.
		await expect(row(pageA, "NewName")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageA, "OldName")).toHaveCount(0);

		// Convergence: tab B shows the renamed folder, old gone, and the child
		// is reachable under the new folder.
		await expect(row(pageB, "NewName")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "OldName")).toHaveCount(0);
		await expandFolder(pageB, "NewName");
		await expect(row(pageB, "child")).toBeVisible({ timeout: 10_000 });

		// Content sync must survive the folder rename. Tabs are anchored on the
		// child note (id stable), so its editor stays bound. Edit in tab A and
		// confirm it converges in tab B.
		const edA = pageA.locator(".cm-content");
		const edB = pageB.locator(".cm-content");
		await edA.click();
		await pageA.keyboard.press("Control+End");
		await pageA.keyboard.type(" EDIT-AFTER-FOLDER-RENAME");
		await expect(edB).toContainText("EDIT-AFTER-FOLDER-RENAME", { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});

	test("move folder propagates to a second tab with its child", async ({ browser, baseURL }) => {
		const email = `e2e-tree-mvf-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treemvf-${Date.now()}`);
		await createFolder(baseURL!, token, vault.id, "Parent");
		await createFolder(baseURL!, token, vault.id, "Movable");
		const { id: childId } = await upsertNote(
			baseURL!,
			token,
			vault.id,
			"Movable/leaf.md",
			"leaf body\n",
		);

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		await signInForNote(pageA, email, vault.id, childId);
		await signInForNote(pageB, email, vault.id, childId);

		await expect(row(pageA, "Movable")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "Parent")).toBeVisible({ timeout: 10_000 });

		// Move the Movable folder under Parent via the Move dialog.
		await openContextMenu(pageA, "Movable");
		await pickAction(pageA, "Move to…");
		await pickMoveTarget(pageA, "Parent");

		// Convergence: in tab B, Movable is now under Parent, carrying its child.
		await expandFolder(pageB, "Parent");
		await expect(row(pageB, "Movable")).toBeVisible({ timeout: 10_000 });
		await expandFolder(pageB, "Movable");
		await expect(row(pageB, "leaf")).toBeVisible({ timeout: 10_000 });

		// Old location clears: Movable is no longer a root-level folder. Collapse
		// Parent so its subtree hides; Movable must then be absent (it now exists
		// only under the collapsed Parent, not at root).
		await row(pageB, "Parent").click();
		await expect(row(pageB, "Parent")).toHaveAttribute("aria-expanded", "false");
		await expect(row(pageB, "Movable")).toHaveCount(0, { timeout: 10_000 });

		// Content sync must survive the folder move. Tabs are anchored on the leaf
		// note (id stable). Re-expand to reach it, then edit in A and converge in B.
		await expandFolder(pageB, "Parent");
		await expandFolder(pageB, "Movable");
		const edA = pageA.locator(".cm-content");
		const edB = pageB.locator(".cm-content");
		await edA.click();
		await pageA.keyboard.press("Control+End");
		await pageA.keyboard.type(" EDIT-AFTER-FOLDER-MOVE");
		await expect(edB).toContainText("EDIT-AFTER-FOLDER-MOVE", { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});

	test("delete non-empty folder propagates to a second tab", async ({ browser, baseURL }) => {
		const email = `e2e-tree-delf-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treedelf-${Date.now()}`);
		await createFolder(baseURL!, token, vault.id, "Doomed");
		await upsertNote(baseURL!, token, vault.id, "Doomed/inside.md", "inside body\n");
		// A surviving root note to anchor both tabs.
		const { id: anchorId } = await upsertNote(baseURL!, token, vault.id, "anchor.md", "anchor\n");

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		await signInForNote(pageA, email, vault.id, anchorId);
		await signInForNote(pageB, email, vault.id, anchorId);

		await expect(row(pageA, "Doomed")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "Doomed")).toBeVisible({ timeout: 10_000 });

		await openContextMenu(pageA, "Doomed");
		await pickAction(pageA, "Delete");
		await confirmDelete(pageA);

		await expect(row(pageA, "Doomed")).toHaveCount(0, { timeout: 10_000 });
		await expect(row(pageB, "Doomed")).toHaveCount(0, { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});

	test("delete EMPTY folder propagates to a second tab", async ({ browser, baseURL }) => {
		const email = `e2e-tree-delef-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treedelef-${Date.now()}`);
		await createFolder(baseURL!, token, vault.id, "Empty");
		const { id: anchorId } = await upsertNote(baseURL!, token, vault.id, "anchor.md", "anchor\n");

		const ctxA = await browser.newContext();
		const pageA = await ctxA.newPage();
		const ctxB = await browser.newContext();
		const pageB = await ctxB.newPage();
		await signInForNote(pageA, email, vault.id, anchorId);
		await signInForNote(pageB, email, vault.id, anchorId);

		await expect(row(pageA, "Empty")).toBeVisible({ timeout: 10_000 });
		await expect(row(pageB, "Empty")).toBeVisible({ timeout: 10_000 });

		await openContextMenu(pageA, "Empty");
		await pickAction(pageA, "Delete");
		await confirmDelete(pageA);

		await expect(row(pageA, "Empty")).toHaveCount(0, { timeout: 10_000 });
		// Predicted red: with no descendant notes, the backend may emit no
		// broadcast, so tab B never invalidates and the folder lingers.
		await expect(row(pageB, "Empty")).toHaveCount(0, { timeout: 10_000 });

		await ctxA.close();
		await ctxB.close();
	});
});
