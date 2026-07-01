import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { DeleteConfirm } from "./delete-confirm";

describe("DeleteConfirm", () => {
	it("renders file message + Delete + Cancel", () => {
		render(
			<DeleteConfirm
				nodes={[{ kind: "file", path: "a.md" }]}
				onConfirm={() => {}}
				onCancel={() => {}}
			/>,
		);
		expect(screen.getByText(/Delete a\.md\?/u)).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Delete" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument();
	});

	it("renders folder message with item count", () => {
		render(
			<DeleteConfirm
				nodes={[{ kind: "folder", path: "src", childCount: 4 }]}
				onConfirm={() => {}}
				onCancel={() => {}}
			/>,
		);
		expect(screen.getByText(/Delete src\/ and 4 items\?/u)).toBeInTheDocument();
	});

	it("Delete button calls onConfirm", () => {
		const onConfirm = vi.fn();
		render(
			<DeleteConfirm
				nodes={[{ kind: "file", path: "a.md" }]}
				onConfirm={onConfirm}
				onCancel={() => {}}
			/>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Delete" }));
		expect(onConfirm).toHaveBeenCalled();
	});

	it("Cancel button calls onCancel", () => {
		const onCancel = vi.fn();
		render(
			<DeleteConfirm
				nodes={[{ kind: "file", path: "a.md" }]}
				onConfirm={() => {}}
				onCancel={onCancel}
			/>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
		expect(onCancel).toHaveBeenCalled();
	});

	it('shows "Delete 3 items?" when N>1', () => {
		const nodes = [
			{ kind: "file" as const, path: "a.md" },
			{ kind: "file" as const, path: "b.md" },
			{ kind: "file" as const, path: "c.md" },
		];
		render(<DeleteConfirm nodes={nodes} onConfirm={vi.fn()} onCancel={vi.fn()} />);
		expect(screen.getByText(/Delete 3 items\?/iu)).toBeInTheDocument();
	});

	it('shows "Delete 2 items?" for mixed file + folder N>1', () => {
		const nodes = [
			{ kind: "file" as const, path: "a.md" },
			{ kind: "folder" as const, path: "src", childCount: 4 },
		];
		render(<DeleteConfirm nodes={nodes} onConfirm={vi.fn()} onCancel={vi.fn()} />);
		expect(screen.getByText(/Delete 2 items\?/iu)).toBeInTheDocument();
	});
});
