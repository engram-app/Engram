import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { PropertyField } from "./property-fields";

/** A YAML block scalar: `desc: |` keeps one trailing newline. */
const BLOCK_SCALAR = "a\nb\n";

/** Values are buttons until tapped; tap one open and return the live input. */
function tapToEdit(label = "x value"): HTMLInputElement {
	fireEvent.click(screen.getByRole("button", { name: new RegExp(`^${label}`) }));
	return screen.getByLabelText(label) as HTMLInputElement;
}

describe("PropertyField", () => {
	// iOS prev/next hops between real text inputs. A value that is a button at
	// rest gives the arrows nowhere to land from the editor.
	test("shows the value as a button, not an input, until tapped", () => {
		render(<PropertyField type="text" value="hi" label="x" onCommit={() => {}} />);
		expect(screen.queryByRole("textbox")).toBeNull();
		expect(screen.getByRole("button", { name: /^x value/ })).toHaveTextContent("hi");
		const input = tapToEdit();
		expect(input).toHaveFocus();
		expect(input).toHaveValue("hi");
	});

	// WCAG 2.5.3 label-in-name (Lighthouse label-content-name-mismatch): a
	// control's accessible name must contain the text it shows.
	test("the at-rest cell's name contains the value it shows", () => {
		render(<PropertyField type="text" value="draft" label="status" onCommit={() => {}} />);
		expect(screen.getByRole("button", { name: "status value: draft" })).toHaveTextContent("draft");
	});

	test("the list adder's name contains its visible text, at full contrast", () => {
		render(<PropertyField type="list" value={[]} label="tags" onCommit={() => {}} />);
		const adder = screen.getByRole("button", { name: "tags value: Add item..." });
		expect(adder).toHaveTextContent("Add item...");
		// A placeholder is exempt from the contrast audit; a button's text is not.
		expect(adder.className).not.toMatch(/text-muted-foreground\/\d+/);
	});

	test("text commits on blur and goes back to a button", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" label="x" onCommit={onCommit} />);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenCalledWith("bye");
		expect(screen.queryByRole("textbox")).toBeNull();
	});

	test("Enter commits without needing the user to click elsewhere", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" label="x" onCommit={onCommit} />);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith("bye");
	});

	test("Escape restores the old value and writes nothing", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" label="x" onCommit={onCommit} />);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.keyDown(input, { key: "Escape" });
		fireEvent.blur(input);
		expect(onCommit).not.toHaveBeenCalled();
		expect(screen.getByRole("button", { name: /^x value/ })).toHaveTextContent("hi");
	});

	// The cancel must not leak into the next edit: a field that was once
	// escaped would otherwise refuse to ever commit again.
	test("commits normally on the edit after an Escape", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" label="x" onCommit={onCommit} />);
		fireEvent.keyDown(tapToEdit(), { key: "Escape" });

		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "later" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith("later");
	});

	// Clearing a value is an edit, not a cancel.
	test("commits an emptied text value", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" label="x" onCommit={onCommit} />);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith("");
	});

	test("number commits a parsed number, null when emptied", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="number" value={3} label="x" onCommit={onCommit} />);
		let input = tapToEdit();
		expect(input).toHaveAttribute("type", "number");
		fireEvent.change(input, { target: { value: "7" } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenLastCalledWith(7);

		input = tapToEdit();
		fireEvent.change(input, { target: { value: "" } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenLastCalledWith(null);
	});

	// YAML block scalars keep a trailing newline and values can carry edge
	// spaces. Opening and closing the cell must not rewrite them.
	test.each([" foo", "a\nb\n"])("a no-op open and close of %j writes nothing", (stored) => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value={stored} label="x" onCommit={onCommit} />);
		fireEvent.blur(tapToEdit());
		expect(onCommit).not.toHaveBeenCalled();
	});

	test("an untouched open value does not overwrite a remote change", () => {
		const onCommit = vi.fn();
		const { rerender } = render(
			<PropertyField type="text" value="old" label="x" onCommit={onCommit} />,
		);
		const input = tapToEdit();
		rerender(<PropertyField type="text" value="remote" label="x" onCommit={onCommit} />);
		fireEvent.blur(input);
		expect(onCommit).not.toHaveBeenCalled();
		expect(screen.getByRole("button", { name: /^x value/ })).toHaveTextContent("remote");
	});

	test("a multi-line value edits in a textarea and keeps its newlines", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value={BLOCK_SCALAR} label="x" onCommit={onCommit} />);
		const box = tapToEdit();
		expect(box.tagName).toBe("TEXTAREA");
		expect(box.className).toMatch(/text-base/);
		fireEvent.change(box, { target: { value: "a\nbc\n" } });
		fireEvent.blur(box);
		expect(onCommit).toHaveBeenCalledWith("a\nbc\n");
	});

	// Swapping input for textarea mid-edit would unmount the focused box and
	// drop the draft. The kind of box is decided once, when it opens.
	test("a remote newline change does not swap the open box", () => {
		const onCommit = vi.fn();
		const { rerender } = render(
			<PropertyField type="text" value="one line" label="x" onCommit={onCommit} />,
		);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "typed" } });
		rerender(<PropertyField type="text" value={BLOCK_SCALAR} label="x" onCommit={onCommit} />);
		expect(input).toBeInTheDocument();
		expect(input).toHaveFocus();
		expect(input).toHaveValue("typed");
	});

	test("an edit is committed verbatim, without trimming", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="a" label="x" onCommit={onCommit} />);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: " padded " } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenCalledWith(" padded ");
	});

	// Switching apps mid-edit used to commit (blur always committed). It must
	// not throw the typed value away.
	test("commits the typed value when the window loses focus", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="a" label="x" onCommit={onCommit} />);
		const input = tapToEdit();
		fireEvent.change(input, { target: { value: "typed" } });
		const hasFocus = vi.spyOn(document, "hasFocus").mockReturnValue(false);
		fireEvent.blur(input);
		hasFocus.mockRestore();
		expect(onCommit).toHaveBeenCalledWith("typed");
	});

	// At rest a date reads the way the native date input showed it, not ISO.
	test("shows a date formatted at rest and the raw value when editing", () => {
		render(<PropertyField type="date" value="2026-06-30" label="x" onCommit={() => {}} />);
		expect(screen.getByRole("button", { name: /^x value/ })).toHaveTextContent("06/30/2026");
		expect(tapToEdit()).toHaveValue("2026-06-30");
	});

	test("shows a datetime formatted at rest", () => {
		render(
			<PropertyField type="datetime" value="2026-06-30T14:05" label="x" onCommit={() => {}} />,
		);
		const text = screen.getByRole("button", { name: /^x value/ }).textContent ?? "";
		expect(text).toContain("06/30/2026");
		expect(text).toMatch(/2:05/);
	});

	test("shows an unparseable date as stored", () => {
		render(<PropertyField type="date" value="someday" label="x" onCommit={() => {}} />);
		expect(screen.getByRole("button", { name: /^x value/ })).toHaveTextContent("someday");
	});

	test("checkbox commits immediately", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="checkbox" value={false} onCommit={onCommit} />);
		fireEvent.click(screen.getByRole("checkbox"));
		expect(onCommit).toHaveBeenCalledWith(true);
	});

	test("list adds a chip on Enter and commits the array", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="list" value={["a"]} label="x" onCommit={onCommit} />);
		expect(screen.queryByRole("textbox")).toBeNull();
		fireEvent.click(screen.getByRole("button", { name: /^x value/ }));
		const input = screen.getByPlaceholderText("Add item...");
		expect(input).toHaveFocus();
		expect(input).toHaveAttribute("autocomplete", "off");
		fireEvent.change(input, { target: { value: "b" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith(["a", "b"]);
	});

	test("Escape in the list adder discards the pending item", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="list" value={["a"]} label="x" onCommit={onCommit} />);
		fireEvent.click(screen.getByRole("button", { name: /^x value/ }));
		const input = screen.getByPlaceholderText("Add item...");
		fireEvent.change(input, { target: { value: "c" } });
		fireEvent.keyDown(input, { key: "Escape" });
		fireEvent.blur(input);
		expect(onCommit).not.toHaveBeenCalled();
	});

	// Tapping outside after typing a tag (instead of Done) used to drop it.
	test("list adder commits the pending item on blur", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="list" value={["a"]} label="x" onCommit={onCommit} />);
		fireEvent.click(screen.getByRole("button", { name: /^x value/ }));
		const input = screen.getByPlaceholderText("Add item...");
		fireEvent.change(input, { target: { value: "c" } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenCalledWith(["a", "c"]);
	});

	// A zone suffix the datetime-local input cannot represent must not be
	// rewritten by merely opening and closing the field.
	test("opening and closing a datetime value writes nothing", () => {
		const onCommit = vi.fn();
		render(
			<PropertyField type="datetime" value="2026-06-30T14:05:00Z" label="x" onCommit={onCommit} />,
		);
		const input = tapToEdit();
		expect(input).toHaveAttribute("type", "datetime-local");
		fireEvent.blur(input);
		expect(onCommit).not.toHaveBeenCalled();
	});
});
