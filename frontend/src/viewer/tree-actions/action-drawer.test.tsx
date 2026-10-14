import { act, fireEvent, render, screen } from "@testing-library/react";
import { PanelRightOpen } from "lucide-react";
import { describe, expect, it, vi } from "vitest";
import { msg } from "@/i18n/msg";
import { untranslated } from "@/i18n/ui-text";
import { ActionDrawer, CLOSE_MS } from "./action-drawer";
import { actionsFor } from "./action-list";

describe("ActionDrawer", () => {
	it("renders title with node name + each action", () => {
		render(
			<ActionDrawer
				title="a.md"
				actions={actionsFor({ kind: "file" })}
				onPick={() => {}}
				onClose={() => {}}
			/>,
		);
		expect(screen.getByText("a.md")).toBeInTheDocument();
		expect(screen.getByRole("menuitem", { name: "Rename" })).toBeInTheDocument();
	});

	// Dismissing slides the sheet down first; it closes once that has played.
	it("Escape slides the sheet out, then closes once", () => {
		vi.useFakeTimers();
		const onClose = vi.fn();
		render(
			<ActionDrawer
				title="a.md"
				actions={actionsFor({ kind: "file" })}
				onPick={() => {}}
				onClose={onClose}
			/>,
		);
		const sheet = screen.getByTestId("action-drawer");
		fireEvent.keyDown(sheet, { key: "Escape" });
		expect(onClose).not.toHaveBeenCalled();
		expect(sheet).toHaveAttribute("data-state", "closed");
		act(() => vi.advanceTimersByTime(CLOSE_MS));
		expect(onClose).toHaveBeenCalledOnce();
		vi.useRealTimers();
	});

	it("puts an extra row in its own group just above the destructive action", () => {
		const onSelect = vi.fn();
		const onClose = vi.fn();
		render(
			<ActionDrawer
				title="a.md"
				actions={actionsFor({ kind: "file" })}
				onPick={() => {}}
				onClose={onClose}
				extra={{ label: untranslated("Open tools"), icon: PanelRightOpen, onSelect }}
			/>,
		);
		const names = screen.getAllByRole("menuitem").map((el) => el.textContent);
		expect(names.slice(-2)).toEqual(["Open tools", "Delete"]);
		fireEvent.click(screen.getByRole("menuitem", { name: "Open tools" }));
		expect(onSelect).toHaveBeenCalledOnce();
		expect(onClose).toHaveBeenCalledOnce();
	});

	it("puts the extra row last when nothing is destructive", () => {
		render(
			<ActionDrawer
				title="a.md"
				actions={[{ id: "rename", label: msg("Rename") }]}
				onPick={() => {}}
				onClose={() => {}}
				extra={{ label: untranslated("Open tools"), icon: PanelRightOpen, onSelect: () => {} }}
			/>,
		);
		const names = screen.getAllByRole("menuitem").map((el) => el.textContent);
		expect(names).toEqual(["Rename", "Open tools"]);
	});

	it("click on action calls onPick then onClose", () => {
		const onPick = vi.fn();
		const onClose = vi.fn();
		render(
			<ActionDrawer
				title="a.md"
				actions={actionsFor({ kind: "file" })}
				onPick={onPick}
				onClose={onClose}
			/>,
		);
		fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
		expect(onPick).toHaveBeenCalledWith("delete");
		expect(onClose).toHaveBeenCalled();
	});

	it("shows Select-more entry when callback provided", async () => {
		const onSelectMore = vi.fn();
		render(
			<ActionDrawer
				title="Some folder"
				actions={[]}
				onPick={vi.fn()}
				onClose={vi.fn()}
				onSelectMore={onSelectMore}
			/>,
		);
		await fireEvent.click(screen.getByRole("button", { name: /Select more/iu }));
		expect(onSelectMore).toHaveBeenCalled();
	});

	it("omits Select-more entry when callback absent (backwards compatible)", () => {
		render(<ActionDrawer title="Some folder" actions={[]} onPick={vi.fn()} onClose={vi.fn()} />);
		expect(screen.queryByRole("button", { name: /Select more/iu })).not.toBeInTheDocument();
	});
});
