import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
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
