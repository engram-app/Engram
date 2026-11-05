import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import LocalSignUp from "./local-sign-up";

const { register, auth, boot } = vi.hoisted(() => ({
	register: vi.fn().mockResolvedValue(undefined),
	auth: { isSignedIn: false },
	boot: {
		value: null as { bootstrap_pending: boolean; registration_mode: string } | null,
	},
}));
vi.mock("./use-auth-adapter", () => ({
	useAuthAdapter: () => ({ register, isSignedIn: auth.isSignedIn }),
}));
vi.mock("./use-bootstrap", () => ({
	useBootstrap: () => boot.value,
}));

function renderPage() {
	return render(
		<MemoryRouter>
			<LocalSignUp />
		</MemoryRouter>,
	);
}

afterEach(() => {
	vi.clearAllMocks();
	auth.isSignedIn = false;
	boot.value = null;
});

describe("LocalSignUp", () => {
	it("blocks submission when passwords do not match", () => {
		renderPage();
		fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.com" } });
		fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret123" } });
		fireEvent.change(screen.getByLabelText("Confirm password"), {
			target: { value: "different1" },
		});
		fireEvent.click(screen.getByRole("button", { name: /create account/iu }));
		expect(screen.getByRole("alert")).toHaveTextContent(/do not match/iu);
		expect(register).not.toHaveBeenCalled();
	});

	it("registers when passwords match", async () => {
		renderPage();
		fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.com" } });
		fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret123" } });
		fireEvent.change(screen.getByLabelText("Confirm password"), { target: { value: "secret123" } });
		fireEvent.click(screen.getByRole("button", { name: /create account/iu }));
		await waitFor(() =>
			expect(register).toHaveBeenCalledWith("a@b.com", "secret123", undefined, undefined),
		);
	});

	it.each([
		["password_too_short", "That password is too short."],
		["invite_invalid", "This invite link is invalid or has already been used."],
		["Some server sentence", "Registration failed"],
	])("shows a translated message for the %s error", async (code, shown) => {
		register.mockRejectedValueOnce(new Error(code));
		renderPage();
		fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.com" } });
		fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret123" } });
		fireEvent.change(screen.getByLabelText("Confirm password"), { target: { value: "secret123" } });
		fireEvent.click(screen.getByRole("button", { name: /create account/iu }));
		expect(await screen.findByRole("alert")).toHaveTextContent(shown);
	});
});

// First-run admin claim: the backend refuses it without the one-time setup
// token from the server log, so the form must collect and send it.
describe("LocalSignUp first-run setup", () => {
	function fillAndSubmit() {
		fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.com" } });
		fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret123" } });
		fireEvent.change(screen.getByLabelText("Confirm password"), { target: { value: "secret123" } });
		fireEvent.click(screen.getByRole("button", { name: /create account/iu }));
	}

	it("sends the setup token with the claim", async () => {
		boot.value = { bootstrap_pending: true, registration_mode: "invite_only" };
		renderPage();
		fireEvent.change(screen.getByLabelText("Setup token"), { target: { value: " tok-123 " } });
		fillAndSubmit();
		await waitFor(() =>
			expect(register).toHaveBeenCalledWith("a@b.com", "secret123", undefined, "tok-123"),
		);
	});

	it("points the operator at the server log", () => {
		boot.value = { bootstrap_pending: true, registration_mode: "invite_only" };
		renderPage();
		expect(screen.getByLabelText("Setup token")).toHaveAccessibleDescription(/server log/iu);
	});

	it("shows a translated message when the token is wrong", async () => {
		boot.value = { bootstrap_pending: true, registration_mode: "invite_only" };
		register.mockRejectedValueOnce(new Error("setup_token_invalid"));
		renderPage();
		fireEvent.change(screen.getByLabelText("Setup token"), { target: { value: "nope" } });
		fillAndSubmit();
		expect(await screen.findByRole("alert")).toHaveTextContent(/setup token is not valid/iu);
	});

	// /sign-in bounces straight back to /sign-up while bootstrap is pending.
	it("hides the sign-in cross-link while no account exists", () => {
		boot.value = { bootstrap_pending: true, registration_mode: "invite_only" };
		renderPage();
		expect(screen.queryByRole("link", { name: /sign in/iu })).not.toBeInTheDocument();
	});

	it("has no setup token field once the instance is claimed", () => {
		boot.value = { bootstrap_pending: false, registration_mode: "open" };
		renderPage();
		expect(screen.queryByLabelText("Setup token")).not.toBeInTheDocument();
		expect(screen.getByRole("link", { name: /sign in/iu })).toBeInTheDocument();
	});
});

const CONSENT_SEARCH = "?return_to=%2Foauth%2Fconsent%3Fclient_id%3Dabc";

// Self-host half of the same dead end the Clerk pages had: a signup that always
// lands on "/" drops an in-flight OAuth authorization, because the consent page
// (the thing that parks it) never got to render.
describe("LocalSignUp return_to", () => {
	function renderAt(search: string) {
		return render(
			<MemoryRouter initialEntries={[`/sign-up${search}`]}>
				<Routes>
					<Route path="/sign-up" element={<LocalSignUp />} />
					<Route path="/oauth/consent" element={<p>consent</p>} />
					<Route path="/" element={<p>home</p>} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("lands a finished signup on the destination that sent them here", () => {
		auth.isSignedIn = true;
		renderAt(CONSENT_SEARCH);
		expect(screen.getByText("consent")).toBeInTheDocument();
	});

	it("still lands on home when nothing sent them here", () => {
		auth.isSignedIn = true;
		renderAt("");
		expect(screen.getByText("home")).toBeInTheDocument();
	});

	it("carries the destination on the sign-in cross-link", () => {
		renderAt(CONSENT_SEARCH);
		expect(screen.getByRole("link", { name: /sign in/iu })).toHaveAttribute(
			"href",
			"/sign-in?return_to=%2Foauth%2Fconsent%3Fclient_id%3Dabc",
		);
	});
});
