import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
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

	// Tapping out slides the sheet down first; it closes once that has played.
	it("backdrop click slides the sheet out, then closes", () => {
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
		fireEvent.click(screen.getByTestId("action-drawer-backdrop"));
		expect(onClose).not.toHaveBeenCalled();
		expect(screen.getByRole("menu")).toHaveClass("animate-out", "slide-out-to-bottom");
		act(() => vi.advanceTimersByTime(CLOSE_MS));
		expect(onClose).toHaveBeenCalledOnce();
		vi.useRealTimers();
	});

	it("a second tap while sliding out does not close twice", () => {
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
		fireEvent.click(screen.getByTestId("action-drawer-backdrop"));
		fireEvent.click(screen.getByTestId("action-drawer-backdrop"));
		act(() => vi.advanceTimersByTime(CLOSE_MS));
		expect(onClose).toHaveBeenCalledOnce();
		vi.useRealTimers();
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
