import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import LocalSignIn from "./local-sign-in";

const { login } = vi.hoisted(() => ({ login: vi.fn().mockResolvedValue(undefined) }));
vi.mock("./use-auth-adapter", () => ({
	useAuthAdapter: () => ({ login, isSignedIn: false }),
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
		expect(screen.getByRole("heading", { name: /sign in to engram/i })).toBeInTheDocument();
		expect(screen.getByLabelText("Email")).toBeInTheDocument();
		expect(screen.getByLabelText("Password")).toBeInTheDocument();
	});

	it("submits the entered credentials", async () => {
		renderPage();
		fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.com" } });
		fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret123" } });
		fireEvent.click(screen.getByRole("button", { name: /sign in/i }));
		await waitFor(() => expect(login).toHaveBeenCalledWith("a@b.com", "secret123"));
	});
});
