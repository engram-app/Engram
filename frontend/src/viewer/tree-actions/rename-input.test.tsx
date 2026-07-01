import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { RenameInput } from "./rename-input";

describe("RenameInput", () => {
	it("autofocuses with initial value and selects basename only", () => {
		render(
			<RenameInput initial="my-note.md" kind="file" onCommit={() => {}} onCancel={() => {}} />,
		);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		expect(input).toHaveFocus();
		expect(input.value).toBe("my-note.md");
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("my-note".length);
	});

	it("selects whole name for folder kind", () => {
		render(
			<RenameInput initial="my-folder" kind="folder" onCommit={() => {}} onCancel={() => {}} />,
		);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("my-folder".length);
	});

	it("Enter calls onCommit with new value", () => {
		const onCommit = vi.fn();
		render(<RenameInput initial="a.md" kind="file" onCommit={onCommit} onCancel={() => {}} />);
		const input = screen.getByRole("textbox");
		fireEvent.change(input, { target: { value: "b.md" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith("b.md");
	});

	it("Enter with unchanged value calls onCancel", () => {
		const onCommit = vi.fn();
		const onCancel = vi.fn();
		render(<RenameInput initial="a.md" kind="file" onCommit={onCommit} onCancel={onCancel} />);
		fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
		expect(onCommit).not.toHaveBeenCalled();
		expect(onCancel).toHaveBeenCalled();
	});

	it("Esc calls onCancel without commit", () => {
		const onCommit = vi.fn();
		const onCancel = vi.fn();
		render(<RenameInput initial="a.md" kind="file" onCommit={onCommit} onCancel={onCancel} />);
		fireEvent.keyDown(screen.getByRole("textbox"), { key: "Escape" });
		expect(onCommit).not.toHaveBeenCalled();
		expect(onCancel).toHaveBeenCalled();
	});

	it("renders inline error when error prop set", () => {
		render(
			<RenameInput
				initial="a.md"
				kind="file"
				onCommit={() => {}}
				onCancel={() => {}}
				error="A file with that name already exists"
			/>,
		);
		expect(screen.getByText(/already exists/u)).toBeInTheDocument();
	});
});
