import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ActionDrawer } from "./action-drawer";
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

	it("backdrop click closes", () => {
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
		expect(onClose).toHaveBeenCalled();
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
		await fireEvent.click(screen.getByRole("button", { name: /Select more/i }));
		expect(onSelectMore).toHaveBeenCalled();
	});

	it("omits Select-more entry when callback absent (backwards compatible)", () => {
		render(<ActionDrawer title="Some folder" actions={[]} onPick={vi.fn()} onClose={vi.fn()} />);
		expect(screen.queryByRole("button", { name: /Select more/i })).not.toBeInTheDocument();
	});
});
