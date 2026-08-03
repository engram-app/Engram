import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { PropertyField } from "./property-fields";

describe("PropertyField", () => {
	test("text commits on blur", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" onCommit={onCommit} />);
		const input = screen.getByRole("textbox");
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenCalledWith("bye");
	});

	// Every other input in the properties widget takes Enter and Escape. The
	// value field took neither, so the most obvious way to say "done" did
	// nothing and there was no way to back out of a half-typed value.
	test("Enter commits without needing the user to click elsewhere", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" onCommit={onCommit} />);
		const input = screen.getByRole("textbox");
		input.focus();
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith("bye");
	});

	test("Escape restores the old value and writes nothing", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" onCommit={onCommit} />);
		const input = screen.getByRole("textbox");
		input.focus();
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.keyDown(input, { key: "Escape" });
		expect(onCommit).not.toHaveBeenCalled();
		expect(input).toHaveValue("hi");
	});

	// The cancel flag must not leak into the next edit: a field that was once
	// escaped would otherwise refuse to ever commit again.
	test("commits normally on the edit after an Escape", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hi" onCommit={onCommit} />);
		const input = screen.getByRole("textbox");
		input.focus();
		fireEvent.change(input, { target: { value: "bye" } });
		fireEvent.keyDown(input, { key: "Escape" });

		input.focus();
		fireEvent.change(input, { target: { value: "later" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith("later");
	});

	test("number commits a parsed number on blur, null when empty", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="number" value={3} onCommit={onCommit} />);
		const input = screen.getByRole("spinbutton");
		fireEvent.change(input, { target: { value: "7" } });
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenLastCalledWith(7);
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
		render(<PropertyField type="list" value={["a"]} onCommit={onCommit} />);
		const input = screen.getByPlaceholderText("Add item...");
		fireEvent.change(input, { target: { value: "b" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommit).toHaveBeenCalledWith(["a", "b"]);
	});

	test("onFocusChange fires on focus and blur", () => {
		const onFocusChange = vi.fn();
		render(
			<PropertyField type="text" value="x" onCommit={() => {}} onFocusChange={onFocusChange} />,
		);
		const input = screen.getByRole("textbox");
		fireEvent.focus(input);
		fireEvent.blur(input);
		expect(onFocusChange).toHaveBeenNthCalledWith(1, true);
		expect(onFocusChange).toHaveBeenNthCalledWith(2, false);
	});

	test("blur without an edit commits the unchanged value verbatim", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="text" value="hello" onCommit={onCommit} />);
		const input = screen.getByRole("textbox");
		fireEvent.focus(input);
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenCalledWith("hello");
	});

	test("datetime value with a zone suffix survives focus+blur untouched", () => {
		const onCommit = vi.fn();
		render(<PropertyField type="datetime" value="2026-06-30T14:05:00Z" onCommit={onCommit} />);
		// datetime-local input doesn't report textbox role; query by type
		const input = document.querySelector('input[type="datetime-local"]') as HTMLInputElement;
		expect(input).not.toBeNull();
		fireEvent.focus(input);
		fireEvent.blur(input);
		expect(onCommit).toHaveBeenCalledWith("2026-06-30T14:05:00Z");
	});
});
