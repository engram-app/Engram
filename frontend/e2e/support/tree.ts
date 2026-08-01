import { expect, type Locator, type Page } from "@playwright/test";

/**
 * Drive a folder row to `want`, tolerating the app changing it underneath us.
 *
 * Folder rows TOGGLE on click, so "read the state, then click if it's wrong" is
 * a check-then-act race: the app auto-expands the chain leading to the active
 * note once that note's fetch resolves (see folder-tree.tsx), which can land
 * between the read and the click. The click then toggles the folder the wrong
 * way, and because the auto-expand is gated to fire once per note, nothing ever
 * puts it back — the row stays wrong forever rather than converging (#1178).
 *
 * `toPass` re-runs the read AND the click together, so a toggle that lands on
 * the wrong side is simply corrected on the next attempt.
 */
async function setFolderExpanded(page: Page, name: string, want: boolean): Promise<void> {
	const folder = row(page, name);
	await expect(folder).toBeVisible();
	const target = want ? "true" : "false";
	await expect(async () => {
		if ((await folder.getAttribute("aria-expanded")) !== target) {
			await folder.click();
		}
		// Short per-attempt timeout: if this click toggled the wrong way we want to
		// retry quickly, not sit on one bad attempt for the whole budget.
		await expect(folder).toHaveAttribute("aria-expanded", target, { timeout: 2000 });
	}).toPass({ timeout: 20_000 });
}

export function treeRoot(page: Page): Locator {
	return page.getByTestId("folder-tree-root");
}

// A tree row is a role="treeitem" whose accessible name is its label
// (folder leaf name, or note title which falls back to filename-without-ext).
export function row(page: Page, name: string): Locator {
	return page.getByRole("treeitem", { name, exact: true });
}

export async function expandFolder(page: Page, name: string): Promise<void> {
	await setFolderExpanded(page, name, true);
}

export async function collapseFolder(page: Page, name: string): Promise<void> {
	await setFolderExpanded(page, name, false);
}

export async function openContextMenu(page: Page, name: string): Promise<void> {
	await row(page, name).click({ button: "right" });
	await expect(page.getByRole("menu")).toBeVisible();
}

export async function pickAction(
	page: Page,
	label: "Rename" | "Move to…" | "Duplicate" | "Delete",
): Promise<void> {
	await page.getByRole("menuitem", { name: label, exact: true }).click();
}

// Inline rename: fill then Enter. Do NOT blur first (blur cancels).
export async function commitRename(page: Page, next: string): Promise<void> {
	const input = page.getByTestId("tree-rename-input");
	await expect(input).toBeVisible();
	await input.fill(next);
	await input.press("Enter");
}

// Move dialog: a combobox listbox. Root option renders as "/ (root)";
// a folder option renders as its full name. Click the option directly.
export async function pickMoveTarget(page: Page, folderLabel: string): Promise<void> {
	const dialog = page.getByRole("dialog");
	await expect(dialog).toBeVisible();
	await dialog.getByRole("option", { name: folderLabel, exact: true }).click();
}

export async function confirmDelete(page: Page): Promise<void> {
	const dialog = page.getByRole("dialog");
	await expect(dialog).toBeVisible();
	await dialog.getByRole("button", { name: "Delete", exact: true }).click();
}
