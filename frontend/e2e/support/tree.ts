import { expect, type Locator, type Page } from "@playwright/test";

export function treeRoot(page: Page): Locator {
	return page.getByTestId("folder-tree-root");
}

// A tree row is a role="treeitem" whose accessible name is its label
// (folder leaf name, or note title which falls back to filename-without-ext).
export function row(page: Page, name: string): Locator {
	return page.getByRole("treeitem", { name, exact: true });
}

// Folder rows toggle expansion on click. Only click when collapsed so we do
// not accidentally collapse an already-open folder.
export async function expandFolder(page: Page, name: string): Promise<void> {
	const folder = row(page, name);
	await expect(folder).toBeVisible();
	if ((await folder.getAttribute("aria-expanded")) !== "true") {
		await folder.click();
		await expect(folder).toHaveAttribute("aria-expanded", "true");
	}
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
