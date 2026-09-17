import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import LocalSignUp from "./local-sign-up";

const { register, auth } = vi.hoisted(() => ({
	register: vi.fn().mockResolvedValue(undefined),
	auth: { isSignedIn: false },
}));
vi.mock("./use-auth-adapter", () => ({
	useAuthAdapter: () => ({ register, isSignedIn: auth.isSignedIn }),
}));
vi.mock("./use-bootstrap", () => ({
	useBootstrap: () => null,
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
		await waitFor(() => expect(register).toHaveBeenCalledWith("a@b.com", "secret123", undefined));
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
