import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, test, vi } from "vitest";
import { PropertyTypeMenu } from "./property-type-menu";

describe("PropertyTypeMenu", () => {
	test("shows current type and emits a new one on select", async () => {
		const onChange = vi.fn();
		render(<PropertyTypeMenu value="text" onChange={onChange} />);
		const trigger = screen.getByRole("button", { name: /property type/i });
		// The trigger is an icon, so the name is the ONLY place the current type
		// is stated — without this a screen reader is told a type picker exists
		// but never which type the property already has.
		expect(trigger).toHaveAccessibleName("Property type: text");
		// Radix DropdownMenu opens on pointerdown in happy-dom
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
		fireEvent.click(trigger);
		const item = await screen.findByRole("menuitem", { name: "list" });
		fireEvent.click(item);
		expect(onChange).toHaveBeenCalledWith("list");
	});
});

// Choosing a type should leave the caret on the property's NAME: the type is
// picked first and the name is what you type next. Radix restores focus to the
// trigger when the menu closes, so this only works from `onCloseAutoFocus` --
// focusing from `onSelect` is silently undone a tick later.
describe("focus after a type is chosen", () => {
	// Testing Library unmounts what IT rendered; a node appended straight to
	// document.body is ours to clean up. Leaving them behind made every later
	// test in this file share a body full of stale focus targets, which broke
	// the sibling test above intermittently under parallel load.
	const targets: HTMLInputElement[] = [];
	afterEach(() => {
		for (const el of targets.splice(0)) {
			el.remove();
		}
	});

	function withTarget() {
		const target = document.createElement("input");
		document.body.appendChild(target);
		targets.push(target);
		return target;
	}

	const open = (name = /property type/i) => {
		const trigger = screen.getByRole("button", { name });
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
		fireEvent.click(trigger);
		return trigger;
	};

	test("hands focus to focusAfterSelect's element when a type is selected", async () => {
		const target = withTarget();
		render(<PropertyTypeMenu value="text" onChange={vi.fn()} focusAfterSelect={() => target} />);
		open();
		fireEvent.click(await screen.findByRole("menuitem", { name: "date" }));
		await waitFor(() => expect(target).toHaveFocus());
	});

	// Escape is the user backing OUT. Redirecting focus there would move them
	// somewhere they never asked to go; the trigger they came from is correct.
	test("leaves focus alone when the menu closes without a selection", async () => {
		const target = withTarget();
		render(<PropertyTypeMenu value="text" onChange={vi.fn()} focusAfterSelect={() => target} />);
		const trigger = open();
		await screen.findByRole("menuitem", { name: "date" });
		fireEvent.keyDown(document.activeElement ?? document.body, { key: "Escape" });
		await waitFor(() => expect(screen.queryByRole("menuitem", { name: "date" })).toBeNull());
		expect(target).not.toHaveFocus();
		expect(trigger).toBeInTheDocument();
	});

	// The redirect must not latch: a selection arms it, and reopening has to
	// disarm it or a later Escape would steal focus on the strength of a choice
	// made minutes earlier.
	test("a selection does not arm the redirect for the NEXT close", async () => {
		const target = withTarget();
		render(<PropertyTypeMenu value="text" onChange={vi.fn()} focusAfterSelect={() => target} />);
		open();
		fireEvent.click(await screen.findByRole("menuitem", { name: "date" }));
		await waitFor(() => expect(target).toHaveFocus());

		target.blur();
		open();
		await screen.findByRole("menuitem", { name: "list" });
		fireEvent.keyDown(document.activeElement ?? document.body, { key: "Escape" });
		await waitFor(() => expect(screen.queryByRole("menuitem", { name: "list" })).toBeNull());
		expect(target).not.toHaveFocus();
	});
});
