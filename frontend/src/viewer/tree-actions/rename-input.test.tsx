import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { RenameInput } from "./rename-input";

/** A YAML block scalar: `desc: |` keeps one trailing newline. */
const BLOCK_SCALAR = "a\nb\n";

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

	// A window blur (alt-tab, devtools, an iPhone app switch) is not the user
	// leaving the field. The comment in the component promised the edit stays
	// open; it used to cancel, and the caller unmounted the typed text.
	it("keeps the edit open with its draft when the WINDOW loses focus", () => {
		const onCommit = vi.fn();
		const onCancel = vi.fn();
		render(
			<RenameInput initial="a" kind="file" commitOnBlur onCommit={onCommit} onCancel={onCancel} />,
		);
		const input = screen.getByRole("textbox");
		fireEvent.change(input, { target: { value: "typed" } });
		const hasFocus = vi.spyOn(document, "hasFocus").mockReturnValue(false);
		fireEvent.blur(input);
		hasFocus.mockRestore();
		expect(onCommit).not.toHaveBeenCalled();
		expect(onCancel).not.toHaveBeenCalled();
		expect(input).toHaveValue("typed");
	});

	it("commits on a window blur when asked to (property values)", () => {
		const onCommit = vi.fn();
		render(
			<RenameInput
				initial="a"
				kind="file"
				commitOnBlur
				commitOnWindowBlur
				onCommit={onCommit}
				onCancel={() => {}}
			/>,
		);
		const input = screen.getByRole("textbox");
		fireEvent.change(input, { target: { value: "typed" } });
		const hasFocus = vi.spyOn(document, "hasFocus").mockReturnValue(false);
		fireEvent.blur(input);
		hasFocus.mockRestore();
		expect(onCommit).toHaveBeenCalledWith("typed");
	});

	// Paths are trimmed; property values must round-trip byte-exact.
	describe("trim={false}", () => {
		it("writes nothing when a value with edge whitespace is opened and closed", () => {
			const onCommit = vi.fn();
			const onCancel = vi.fn();
			render(
				<RenameInput
					initial=" foo "
					trim={false}
					allowEmpty
					commitOnBlur
					onCommit={onCommit}
					onCancel={onCancel}
				/>,
			);
			fireEvent.blur(screen.getByRole("textbox"));
			expect(onCommit).not.toHaveBeenCalled();
			expect(onCancel).toHaveBeenCalled();
		});

		it("commits an edit verbatim, whitespace included", () => {
			const onCommit = vi.fn();
			render(
				<RenameInput
					initial="a"
					trim={false}
					commitOnBlur
					onCommit={onCommit}
					onCancel={() => {}}
				/>,
			);
			const input = screen.getByRole("textbox");
			fireEvent.change(input, { target: { value: "  b " } });
			fireEvent.keyDown(input, { key: "Enter" });
			expect(onCommit).toHaveBeenCalledWith("  b ");
		});
	});

	// A remote change to the value being edited (Obsidian, another tab) must not
	// select the draft: the next keystroke would replace everything typed.
	it("leaves the draft and its caret alone when `initial` changes mid-edit", () => {
		const { rerender } = render(
			<RenameInput initial="a" kind="file" onCommit={() => {}} onCancel={() => {}} />,
		);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		fireEvent.change(input, { target: { value: "draft" } });
		input.setSelectionRange(5, 5);
		rerender(<RenameInput initial="remote" kind="file" onCommit={() => {}} onCancel={() => {}} />);
		expect(input.value).toBe("draft");
		expect(input.selectionStart).toBe(5);
		expect(input.selectionEnd).toBe(5);
	});

	// An untouched draft must not write the value it opened with over a
	// remote change that landed while it was open.
	it("cancels an untouched draft even after `initial` changed under it", () => {
		const onCommit = vi.fn();
		const onCancel = vi.fn();
		const { rerender } = render(
			<RenameInput initial="old" commitOnBlur onCommit={onCommit} onCancel={onCancel} />,
		);
		rerender(<RenameInput initial="remote" commitOnBlur onCommit={onCommit} onCancel={onCancel} />);
		fireEvent.blur(screen.getByRole("textbox"));
		expect(onCommit).not.toHaveBeenCalled();
		expect(onCancel).toHaveBeenCalled();
	});

	// Block-scalar values carry newlines; an <input> strips them on the first
	// keystroke, so a multi-line box is a textarea.
	it("edits a multi-line value in a textarea, newlines kept", () => {
		const onCommit = vi.fn();
		render(
			<RenameInput
				initial={BLOCK_SCALAR}
				multiline
				trim={false}
				commitOnBlur
				onCommit={onCommit}
				onCancel={() => {}}
			/>,
		);
		const box = screen.getByRole("textbox");
		expect(box.tagName).toBe("TEXTAREA");
		expect(box).toHaveValue("a\nb\n");
		// Enter is a newline here, not a commit.
		fireEvent.keyDown(box, { key: "Enter" });
		expect(onCommit).not.toHaveBeenCalled();
		fireEvent.change(box, { target: { value: "a\nbc\n" } });
		fireEvent.blur(box);
		expect(onCommit).toHaveBeenCalledWith("a\nbc\n");
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
