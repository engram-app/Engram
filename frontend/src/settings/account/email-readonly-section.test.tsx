import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { EmailReadonlySection } from "./email-readonly-section";

const meData = { id: 1, email: "me@example.com", role: "member", display_name: null };
vi.mock("../../api/queries", () => ({ useMe: () => ({ data: meData }) }));

describe("EmailReadonlySection", () => {
	it("renders the user email", () => {
		render(<EmailReadonlySection />);
		expect(screen.getByText("me@example.com")).toBeInTheDocument();
	});

	it("mentions contacting an admin", () => {
		render(<EmailReadonlySection />);
		expect(screen.getByText(/contact your admin/iu)).toBeInTheDocument();
	});

	it("copy button writes to clipboard", async () => {
		const writeText = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, "clipboard", {
			value: { writeText },
			writable: true,
			configurable: true,
		});

		render(<EmailReadonlySection />);
		fireEvent.click(screen.getByRole("button", { name: /copy email/iu }));

		expect(writeText).toHaveBeenCalledWith("me@example.com");
	});
});
