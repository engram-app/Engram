import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { MobileHeaderSlot } from "@/layout/mobile-header-slot";
import { DocumentHeader } from "./document-header";

function inMobileLayout(ui: React.ReactNode) {
	const slot = document.createElement("div");
	document.body.append(slot);
	render(
		<MobileHeaderSlot.Provider value={{ slot, openTools: () => undefined }}>
			{ui}
		</MobileHeaderSlot.Provider>,
	);
	return slot;
}

describe("DocumentHeader on mobile", () => {
	it("drops the strip for a page that shows its own title, floating the actions", () => {
		const slot = inMobileLayout(
			<DocumentHeader name="note" inlineTitle actions={<button type="button">act</button>} />,
		);
		expect(screen.queryByText("note")).not.toBeInTheDocument();
		expect(slot).toContainElement(screen.getByRole("button", { name: "act" }));
	});

	// An attachment has no title of its own: without the strip a phone showed
	// no filename anywhere, only a floating Download button.
	it("keeps the strip, name and actions, for a page with no title of its own", () => {
		const slot = inMobileLayout(
			<DocumentHeader name="photo.png" actions={<button type="button">act</button>} />,
		);
		expect(screen.getByText("photo.png")).toBeInTheDocument();
		expect(slot).not.toContainElement(screen.getByRole("button", { name: "act" }));
	});
});
