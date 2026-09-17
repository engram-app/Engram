import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import LocalSignIn from "./local-sign-in";

const { login } = vi.hoisted(() => ({ login: vi.fn().mockResolvedValue(undefined) }));
vi.mock("./use-auth-adapter", () => ({
	useAuthAdapter: () => ({ login, isSignedIn: false }),
}));
const { boot } = vi.hoisted(() => ({
	boot: { state: { registration_mode: "open", bootstrap_pending: false } },
}));
vi.mock("./use-bootstrap", () => ({
	useBootstrap: () => boot.state,
}));

function renderPage() {
	return render(
		<MemoryRouter>
			<LocalSignIn />
		</MemoryRouter>,
	);
}

afterEach(() => {
	vi.clearAllMocks();
	boot.state = { registration_mode: "open", bootstrap_pending: false };
});

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

// The first-run bounce is a SECOND, programmatic /sign-in -> /sign-up hop,
// nine lines above the visible link. Leaving it bare strands the operator:
// AuthGuard stashes a device code under `return_to=/link`, this bounce drops
// it, and the finished signup lands on "/" with the code never redeemed.
function SignUpProbe() {
	const { search } = useLocation();
	return <p data-testid="signup">signup{search}</p>;
}

describe("LocalSignIn first-run bounce", () => {
	function renderAt(search: string) {
		return render(
			<MemoryRouter initialEntries={[`/sign-in${search}`]}>
				<Routes>
					<Route path="/sign-in" element={<LocalSignIn />} />
					<Route path="/sign-up" element={<SignUpProbe />} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("carries the destination into the bootstrap signup", () => {
		boot.state = { registration_mode: "open", bootstrap_pending: true };
		renderAt("?return_to=%2Flink");
		expect(screen.getByTestId("signup")).toHaveTextContent("?return_to=%2Flink");
	});

	it("bounces bare when nothing sent them here", () => {
		boot.state = { registration_mode: "open", bootstrap_pending: true };
		renderAt("");
		expect(screen.getByTestId("signup")).toHaveTextContent("signup");
	});
});
