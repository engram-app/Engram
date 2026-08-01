import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { RenameInput } from "./rename-input";

describe("RenameInput", () => {
	it("autofocuses and selects the whole name", () => {
		render(<RenameInput initial="my-note" kind="file" onCommit={() => {}} onCancel={() => {}} />);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		expect(input).toHaveFocus();
		expect(input.value).toBe("my-note");
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("my-note".length);
	});

	// Callers seed this with a base name, never a leaf with an extension, so a
	// dot is title text — selecting up to it would leave ".js guide" behind.
	it("selects through a dot in a dotted title", () => {
		render(
			<RenameInput initial="Node.js guide" kind="file" onCommit={() => {}} onCancel={() => {}} />,
		);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("Node.js guide".length);
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

	it("blur cancels by default, so the tree keeps its click-away-to-abandon behaviour", () => {
		const onCommit = vi.fn();
		const onCancel = vi.fn();
		render(<RenameInput initial="a.md" kind="file" onCommit={onCommit} onCancel={onCancel} />);
		fireEvent.change(screen.getByRole("textbox"), { target: { value: "b.md" } });
		fireEvent.blur(screen.getByRole("textbox"));
		expect(onCommit).not.toHaveBeenCalled();
		expect(onCancel).toHaveBeenCalled();
	});

	describe("commitOnBlur", () => {
		it("saves the edit when focus leaves, without needing Enter", () => {
			const onCommit = vi.fn();
			render(
				<RenameInput
					initial="a.md"
					kind="file"
					commitOnBlur
					onCommit={onCommit}
					onCancel={() => {}}
				/>,
			);
			fireEvent.change(screen.getByRole("textbox"), { target: { value: "b.md" } });
			fireEvent.blur(screen.getByRole("textbox"));
			expect(onCommit).toHaveBeenCalledWith("b.md");
		});

		it("cancels on blur when the value is unchanged", () => {
			// Clicking in and straight back out is not a rename.
			const onCommit = vi.fn();
			const onCancel = vi.fn();
			render(
				<RenameInput
					initial="a.md"
					kind="file"
					commitOnBlur
					onCommit={onCommit}
					onCancel={onCancel}
				/>,
			);
			fireEvent.blur(screen.getByRole("textbox"));
			expect(onCommit).not.toHaveBeenCalled();
			expect(onCancel).toHaveBeenCalled();
		});

		it("does not commit twice when Enter is followed by blur", () => {
			// Enter commits and the parent may keep the input mounted long enough
			// for the browser to fire blur as focus moves away. Renaming twice would
			// fire a second mutation against a path that no longer exists.
			const onCommit = vi.fn();
			render(
				<RenameInput
					initial="a.md"
					kind="file"
					commitOnBlur
					onCommit={onCommit}
					onCancel={() => {}}
				/>,
			);
			const input = screen.getByRole("textbox");
			fireEvent.change(input, { target: { value: "b.md" } });
			fireEvent.keyDown(input, { key: "Enter" });
			fireEvent.blur(input);
			expect(onCommit).toHaveBeenCalledTimes(1);
		});

		it("does not resurrect an abandoned edit when Escape is followed by blur", () => {
			// Escape means discard. Committing on the blur that follows would undo
			// the abandonment and save the very edit that was just thrown away.
			const onCommit = vi.fn();
			const onCancel = vi.fn();
			render(
				<RenameInput
					initial="a.md"
					kind="file"
					commitOnBlur
					onCommit={onCommit}
					onCancel={onCancel}
				/>,
			);
			const input = screen.getByRole("textbox");
			fireEvent.change(input, { target: { value: "b.md" } });
			fireEvent.keyDown(input, { key: "Escape" });
			fireEvent.blur(input);
			expect(onCommit).not.toHaveBeenCalled();
			expect(onCancel).toHaveBeenCalledTimes(1);
		});
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
