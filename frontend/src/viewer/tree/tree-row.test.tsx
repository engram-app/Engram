import { fireEvent, render, screen } from "@testing-library/react";
import { act } from "react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { LoaderItem } from "./loader";
import { TreeRow } from "./tree-row";
import type { TreeItem } from "./types";

const folderItem: TreeItem = {
	kind: "folder",
	id: "1",
	path: "Projects",
	name: "Projects",
	count: 3,
};
const noteItem: TreeItem = {
	kind: "note",
	id: "100",
	path: "Projects/a.md",
	title: "a",
	ext: "md",
};
const orgNote: TreeItem = {
	kind: "note",
	id: "101",
	path: "Projects/b.org",
	title: "b",
	ext: "org",
};
const attachmentItem: TreeItem = {
	kind: "attachment",
	id: "att-1",
	path: "img/a.png",
	mime: "image/png",
	size: 10,
};

interface InstanceOverrides {
	data?: TreeItem;
	props?: Record<string, unknown>;
	isExpanded?: boolean;
	isSelected?: boolean;
	isFocused?: boolean;
	isRenaming?: boolean;
	level?: number;
	completeRenaming?: () => void;
	abortRenaming?: () => void;
	renameInputProps?: Record<string, unknown>;
}

function mockInstance(overrides: InstanceOverrides = {}) {
	const data = overrides.data ?? folderItem;
	const itemIdStr =
		data.kind === "folder"
			? `f:${data.id}`
			: data.kind === "note"
				? `n:${data.id}`
				: `a:${data.path.split("/").map(encodeURIComponent).join("/")}`;
	const loaderItem: LoaderItem = {
		itemId: itemIdStr,
		item: data,
		isFolder: data.kind === "folder",
	};
	const completeRenaming = overrides.completeRenaming ?? vi.fn();
	const abortRenaming = overrides.abortRenaming ?? vi.fn();
	return {
		getId: () => loaderItem.itemId,
		getItemData: () => loaderItem,
		getProps: () => overrides.props ?? {},
		getItemMeta: () => ({ level: overrides.level ?? 0 }),
		isExpanded: () => overrides.isExpanded ?? false,
		isSelected: () => overrides.isSelected ?? false,
		isFocused: () => overrides.isFocused ?? false,
		isRenaming: () => overrides.isRenaming ?? false,
		getRenameInputProps: () => overrides.renameInputProps ?? {},
		getTree: () => ({
			completeRenaming,
			abortRenaming,
			getRenamingValue: () => "",
		}),
	} as never;
}

describe("TreeRow", () => {
	it("renders folder name", () => {
		const instance = mockInstance({ data: folderItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		expect(screen.getByText("Projects")).toBeInTheDocument();
	});

	it("folder row exposes aria-expanded matching HT state", () => {
		const instance = mockInstance({ data: folderItem, isExpanded: true });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		expect(screen.getByRole("treeitem")).toHaveAttribute("aria-expanded", "true");
	});

	it("renders note as link to /note/:id", () => {
		const instance = mockInstance({ data: noteItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const link = screen.getByRole("link") as HTMLAnchorElement;
		expect(link.getAttribute("href")).toBe("/note/100");
		expect(screen.getByText("a")).toBeInTheDocument();
	});

	it("shows uppercase ext badge for non-md notes", () => {
		const instance = mockInstance({ data: orgNote });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const badge = screen.getByText("org");
		expect(badge).toBeInTheDocument();
		expect(badge.className).toMatch(/uppercase/u);
	});

	it("omits ext badge for md notes", () => {
		const instance = mockInstance({ data: noteItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		expect(screen.queryByText("md")).not.toBeInTheDocument();
	});

	it("renders RenameInput when isRenaming is true", () => {
		const instance = mockInstance({ data: folderItem, isRenaming: true });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		expect(screen.getByRole("textbox")).toBeInTheDocument();
	});

	// The highlight is pinned to the OPEN file (the route), not to whatever was
	// clicked last. Clicking a folder expands it; it must not steal the chip.
	describe("active highlight", () => {
		const chip = /bg-tree-selected/u;

		it("paints the note that matches the open route id", () => {
			const instance = mockInstance({ data: noteItem });
			render(
				<MemoryRouter>
					<TreeRow instance={instance} activeId="100" />
				</MemoryRouter>,
			);
			const link = screen.getByRole("link");
			expect(link.className).toMatch(chip);
			expect(link).toHaveAttribute("aria-current", "page");
		});

		it("paints an open attachment too", () => {
			const instance = mockInstance({ data: attachmentItem });
			render(
				<MemoryRouter>
					<TreeRow instance={instance} activeId="att-1" />
				</MemoryRouter>,
			);
			expect(screen.getByRole("link").className).toMatch(chip);
		});

		it("does not paint a note that is merely HT-selected but not open", () => {
			const instance = mockInstance({ data: noteItem, isSelected: true });
			render(
				<MemoryRouter>
					<TreeRow instance={instance} activeId="999" />
				</MemoryRouter>,
			);
			const link = screen.getByRole("link");
			expect(link.className).not.toMatch(chip);
			expect(link).not.toHaveAttribute("aria-current");
		});

		it("never paints a folder, even when HT has it selected", () => {
			const instance = mockInstance({ data: folderItem, isSelected: true });
			render(
				<MemoryRouter>
					<TreeRow instance={instance} activeId="1" />
				</MemoryRouter>,
			);
			expect(screen.getByRole("treeitem").className).not.toMatch(chip);
		});
	});

	it("aria-selected reflects HT selection state on note link", () => {
		const instance = mockInstance({ data: noteItem, isSelected: true });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		expect(screen.getByRole("link")).toHaveAttribute("aria-selected", "true");
	});

	it("aria-selected reflects HT selection state on folder button", () => {
		const instance = mockInstance({ data: folderItem, isSelected: true });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		expect(screen.getByRole("treeitem")).toHaveAttribute("aria-selected", "true");
	});

	it("indents by depth × 12px via getItemMeta().level", () => {
		const instance = mockInstance({ data: folderItem, level: 2 });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const btn = screen.getByRole("treeitem");
		expect(btn.style.paddingLeft).toBe("28px"); // 2 * 12 + 4
	});

	it("invokes onContextMenu with item id + clientX/Y on right-click of a folder row", () => {
		const onContextMenu = vi.fn();
		const instance = mockInstance({ data: folderItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} onContextMenu={onContextMenu} />
			</MemoryRouter>,
		);
		fireEvent.contextMenu(screen.getByRole("treeitem"), { clientX: 42, clientY: 99 });
		expect(onContextMenu).toHaveBeenCalledWith("f:1", 42, 99);
	});

	// A synthetic folder used to get NO handler, which meant right-clicking it
	// opened the browser's own context menu. It gets ours now — narrowed to the
	// path-keyed actions by `actionsFor({ synthetic: true })`, not suppressed
	// here. Most folders in a real vault are synthetic (`/api/folders` returns
	// derived folders with a null id), so this was the common case.
	it("invokes onContextMenu on a synthetic (syn:) folder row too", () => {
		const onContextMenu = vi.fn();
		const synthetic: TreeItem = {
			kind: "folder",
			id: "syn:pics",
			path: "pics",
			name: "pics",
			count: 0,
		};
		const instance = mockInstance({ data: synthetic });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} onContextMenu={onContextMenu} />
			</MemoryRouter>,
		);
		const ev = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
		fireEvent(screen.getByRole("treeitem"), ev);
		expect(onContextMenu).toHaveBeenCalledWith("f:syn:pics", 0, 0);
		// preventDefault is what keeps the native menu from appearing.
		expect(ev.defaultPrevented).toBe(true);
	});

	it("invokes onContextMenu with item id + clientX/Y on right-click of an attachment row", () => {
		const onContextMenu = vi.fn();
		const instance = mockInstance({ data: attachmentItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} onContextMenu={onContextMenu} />
			</MemoryRouter>,
		);
		fireEvent.contextMenu(screen.getByRole("link"), { clientX: 42, clientY: 99 });
		expect(onContextMenu).toHaveBeenCalledWith("a:img/a.png", 42, 99);
	});

	it("invokes onContextMenu with item id + clientX/Y on right-click of a note row", () => {
		const onContextMenu = vi.fn();
		const instance = mockInstance({ data: noteItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} onContextMenu={onContextMenu} />
			</MemoryRouter>,
		);
		fireEvent.contextMenu(screen.getByRole("link"), { clientX: 10, clientY: 20 });
		expect(onContextMenu).toHaveBeenCalledWith("n:100", 10, 20);
	});

	it("invokes onLongPress with item id after the long-press delay (touch)", () => {
		vi.useFakeTimers();
		const onLongPress = vi.fn();
		const instance = mockInstance({ data: noteItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} onLongPress={onLongPress} />
			</MemoryRouter>,
		);
		const link = screen.getByRole("link");
		act(() => {
			fireEvent.pointerDown(link, { pointerType: "touch", clientX: 5, clientY: 5 });
		});
		act(() => {
			vi.advanceTimersByTime(600);
		});
		expect(onLongPress).toHaveBeenCalledWith("n:100");
		vi.useRealTimers();
	});

	it("does NOT invoke onLongPress for a mouse pointer (mouse drag must not trip it)", () => {
		vi.useFakeTimers();
		const onLongPress = vi.fn();
		const instance = mockInstance({ data: noteItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} onLongPress={onLongPress} />
			</MemoryRouter>,
		);
		const link = screen.getByRole("link");
		act(() => {
			fireEvent.pointerDown(link, { pointerType: "mouse", clientX: 5, clientY: 5 });
		});
		act(() => {
			vi.advanceTimersByTime(600);
		});
		expect(onLongPress).not.toHaveBeenCalled();
		vi.useRealTimers();
	});

	it("spreads HT row props onto the rendered element", () => {
		const instance = mockInstance({
			data: folderItem,
			props: { "data-ht": "yes", tabIndex: -1 },
		});
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const btn = screen.getByRole("treeitem");
		expect(btn).toHaveAttribute("data-ht", "yes");
		expect(btn).toHaveAttribute("tabindex", "-1");
	});

	it("strips the native link payload on a note dragstart (no browser split/new-tab offer) while preserving HT drag init", () => {
		const htDragStart = vi.fn();
		const instance = mockInstance({ data: noteItem, props: { onDragStart: htDragStart } });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const link = screen.getByRole("link");
		const clearData = vi.fn();
		fireEvent.dragStart(link, {
			dataTransfer: { clearData, setData: vi.fn(), types: [] },
		});
		// HT's own drag initialization must still run.
		expect(htDragStart).toHaveBeenCalledOnce();
		// The <a href> link payload Chrome uses for split-view must be cleared.
		expect(clearData).toHaveBeenCalledWith("text/uri-list");
		expect(clearData).toHaveBeenCalledWith("text/plain");
	});

	it("renders attachment as a link to /note/:id (uuid, not path)", () => {
		const instance = mockInstance({ data: attachmentItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const link = screen.getByRole("link") as HTMLAnchorElement;
		expect(link.getAttribute("href")).toBe("/note/att-1");
		// Base name only — the extension lives in the badge beside it.
		expect(screen.getByText("a")).toBeInTheDocument();
		expect(screen.queryByText("a.png")).not.toBeInTheDocument();
	});

	it("shows uppercase ext badge for attachment", () => {
		const instance = mockInstance({ data: attachmentItem });
		render(
			<MemoryRouter>
				<TreeRow instance={instance} />
			</MemoryRouter>,
		);
		const badge = screen.getByText("PNG");
		expect(badge).toBeInTheDocument();
	});
});
