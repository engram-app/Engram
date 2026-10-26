import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { PropertyField } from "./property-fields";

/** Values are buttons until tapped; tap one open and return the live input. */
function tapToEdit(label = "x value"): HTMLInputElement {
	fireEvent.click(screen.getByRole("button", { name: label }));
	return screen.getByLabelText(label) as HTMLInputElement;
}

describe("PropertyField", () => {
	// iOS prev/next hops between real text inputs. A value that is a button at
	// rest gives the arrows nowhere to land from the editor.
	test("shows the value as a button, not an input, until tapped", () => {
		render(<PropertyField type="text" value="hi" label="x" onCommit={() => {}} />);
		expect(screen.queryByRole("textbox")).toBeNull();
		expect(screen.getByRole("button", { name: "x value" })).toHaveTextContent("hi");
		const input = tapToEdit();
		expect(input).toHaveFocus();
		expect(input).toHaveValue("hi");
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
		expect(screen.getByRole("button", { name: "x value" })).toHaveTextContent("hi");
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
		fireEvent.click(screen.getByRole("button", { name: "x value" }));
		const input = screen.getByPlaceholderText("Add item...");
		expect(input).toHaveFocus();
		expect(input).toHaveAttribute("autocomplete", "off");
		fireEvent.change(input, { target: { value: "b" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith(["a", "b"]);
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
