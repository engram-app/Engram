import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { markAccountConflict } from "./signup-rejection";
import SignupRejectionNotice from "./signup-rejection-notice";

describe("SignupRejectionNotice", () => {
	beforeEach(() => {
		sessionStorage.clear();
	});

	it("shows the contact-support message after an account_conflict sign-out", () => {
		markAccountConflict();

		render(<SignupRejectionNotice />);

		const alert = screen.getByRole("alert");
		expect(alert).toHaveTextContent(/already exists/iu);
		expect(alert).toHaveTextContent(/contact support/iu);
	});

	it("renders nothing without a recorded conflict", () => {
		const { container } = render(<SignupRejectionNotice />);

		expect(container).toBeEmptyDOMElement();
	});

	it("shows once: the flag is cleared after it is read", () => {
		markAccountConflict();
		const { unmount } = render(<SignupRejectionNotice />);
		unmount();

		const { container } = render(<SignupRejectionNotice />);

		expect(container).toBeEmptyDOMElement();
	});
});
