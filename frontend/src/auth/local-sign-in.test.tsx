import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import LocalSignIn from "./local-sign-in";

const { login } = vi.hoisted(() => ({ login: vi.fn().mockResolvedValue(undefined) }));
vi.mock("./use-auth-adapter", () => ({
	useAuthAdapter: () => ({ login, isSignedIn: false }),
}));
vi.mock("./use-bootstrap", () => ({
	useBootstrap: () => ({ registration_mode: "open", bootstrap_pending: false }),
}));

function renderPage() {
	return render(
		<MemoryRouter>
			<LocalSignIn />
		</MemoryRouter>,
	);
}

afterEach(() => vi.clearAllMocks());

describe("LocalSignIn", () => {
	it("renders the sign-in form", () => {
		renderPage();
		expect(screen.getByRole("heading", { name: /sign in to engram/iu })).toBeInTheDocument();
		expect(screen.getByLabelText("Email")).toBeInTheDocument();
		expect(screen.getByLabelText("Password")).toBeInTheDocument();
	});

	it("submits the entered credentials", async () => {
		renderPage();
		fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.com" } });
		fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret123" } });
		fireEvent.click(screen.getByRole("button", { name: /sign in/iu }));
		await waitFor(() => expect(login).toHaveBeenCalledWith("a@b.com", "secret123"));
	});
});

// The sign-up cross-link is a plain href. A bare one drops the destination
// before /sign-up can read it, which is how a signup started mid-OAuth lost
// the whole authorization request.
describe("LocalSignIn sign-up cross-link", () => {
	it("carries the destination that sent them here", () => {
		render(
			<MemoryRouter initialEntries={["/sign-in?return_to=%2Foauth%2Fconsent%3Fclient_id%3Dabc"]}>
				<LocalSignIn />
			</MemoryRouter>,
		);
		expect(screen.getByRole("link", { name: /sign up/iu })).toHaveAttribute(
			"href",
			"/sign-up?return_to=%2Foauth%2Fconsent%3Fclient_id%3Dabc",
		);
	});

	it("stays bare for an ordinary sign-in", () => {
		render(
			<MemoryRouter initialEntries={["/sign-in"]}>
				<LocalSignIn />
			</MemoryRouter>,
		);
		expect(screen.getByRole("link", { name: /sign up/iu })).toHaveAttribute("href", "/sign-up");
	});
});
