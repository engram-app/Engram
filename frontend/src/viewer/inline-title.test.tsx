import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { InlineTitle } from "./inline-title";

const props = {
	name: "My Note",
	renaming: false,
	onStartRename: vi.fn(),
	onCommitRename: vi.fn(),
	onCancelRename: vi.fn(),
};

describe("InlineTitle", () => {
	it("renders the name as a level-1 heading", () => {
		render(<InlineTitle {...props} />);
		expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("My Note");
	});

	it("starts a rename when clicked", () => {
		const onStartRename = vi.fn();
		render(<InlineTitle {...props} onStartRename={onStartRename} />);
		fireEvent.click(screen.getByRole("button", { name: "My Note" }));
		expect(onStartRename).toHaveBeenCalled();
	});

	it("shows an input seeded with the name, fully selected, while renaming", () => {
		render(<InlineTitle {...props} renaming />);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		expect(input.value).toBe("My Note");
		// Typing must replace the name, which is what the selection buys.
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("My Note".length);
	});

	it("commits the typed name on Enter", () => {
		const onCommitRename = vi.fn();
		render(<InlineTitle {...props} renaming onCommitRename={onCommitRename} />);
		const input = screen.getByRole("textbox");
		fireEvent.change(input, { target: { value: "Renamed" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommitRename).toHaveBeenCalledWith("Renamed");
	});
});
