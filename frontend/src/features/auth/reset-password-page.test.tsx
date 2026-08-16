/**
 * The password-reset token's lifecycle.
 *
 * The token IS the credential that lets its bearer set this account's
 * password. While it sits in the address bar it is in browser history, in the
 * Referer of everything the page loads, and on every Sentry event as
 * request.url — so the page captures it once and scrubs it.
 *
 * Scrubbing it is the easy half. The hard half is that the page must still
 * work afterwards: a reload after "passwords do not match" used to strand the
 * user with no way forward but re-opening the email. That regression is what
 * these tests exist for, and until now this page had no tests at all.
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { stashCredential } from "@/auth/credential-handoff";
import ResetPasswordPage from "./ResetPasswordPage";

// AuthShell renders ThemeToggle, which reads a theme context this suite has no
// reason to provide. Same stub the device-link suite uses.
vi.mock("@/theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

function LocationProbe() {
	const { pathname, search } = useLocation();
	return <span data-testid="location">{`${pathname}${search}`}</span>;
}

// Remounts on each render() call, which is how a reload is simulated: the
// component's useState initialiser runs again against the same sessionStorage.
function renderPage(entry: string) {
	return render(
		<MemoryRouter initialEntries={[entry]}>
			<Routes>
				<Route
					path="/reset-password"
					element={
						<>
							<ResetPasswordPage />
							<LocationProbe />
						</>
					}
				/>
			</Routes>
		</MemoryRouter>,
	);
}

// fireEvent, not user-event: it is not a dependency of this package and the
// sibling suites all use fireEvent.
async function submitPasswords(value: string) {
	fireEvent.change(screen.getByLabelText(/new password/iu), { target: { value } });
	fireEvent.change(screen.getByLabelText(/confirm password/iu), { target: { value } });
	fireEvent.click(screen.getByRole("button", { name: /set password/iu }));
}

/** The JSON body of the nth fetch call, with the index narrowed. */
function sentBody(call: number): { token?: string; password?: string } {
	const args = fetchMock.mock.calls[call];
	if (!args) {
		throw new Error(`no fetch call at index ${call}`);
	}
	return JSON.parse((args[1] as { body: string }).body);
}

const fetchMock = vi.fn();

beforeEach(() => {
	window.sessionStorage.clear();
	vi.stubGlobal("fetch", fetchMock);
	fetchMock.mockResolvedValue({ ok: true, json: async () => ({}) });
});

afterEach(() => {
	vi.unstubAllGlobals();
	vi.clearAllMocks();
});

describe("ResetPasswordPage token handling", () => {
	it("scrubs the token out of the URL", async () => {
		renderPage("/reset-password?token=secret-tok");

		await waitFor(() =>
			expect(screen.getByTestId("location")).toHaveTextContent("/reset-password"),
		);
		expect(screen.getByTestId("location").textContent).not.toContain("secret-tok");
	});

	it("still submits the token it scrubbed", async () => {
		renderPage("/reset-password?token=secret-tok");
		await submitPasswords("hunter2hunter2");

		await waitFor(() => expect(fetchMock).toHaveBeenCalled());
		expect(sentBody(0).token).toBe("secret-tok");
	});

	// The regression: mistype, reload, and the token is gone from the URL AND
	// from history. Twice, because `take` deletes on read — the first fix put
	// it back, and this is what proves that.
	it("survives two reloads after the scrub", async () => {
		renderPage("/reset-password?token=secret-tok").unmount();
		renderPage("/reset-password").unmount();
		renderPage("/reset-password");

		await submitPasswords("hunter2hunter2");

		await waitFor(() => expect(fetchMock).toHaveBeenCalled());
		expect(sentBody(0).token).toBe("secret-tok");
	});

	// Spent tokens must not be replayable from a tab left open.
	it("clears the handoff once the reset succeeds", async () => {
		renderPage("/reset-password?token=secret-tok");
		await submitPasswords("hunter2hunter2");
		await screen.findByText(/password updated/iu);

		expect(window.sessionStorage.getItem("engram:handoff:token")).toBeNull();
	});

	// A failed submit is the mistype case — the token has to survive it, or the
	// retry the user is about to make cannot work.
	it("keeps the token available after a failed submit", async () => {
		fetchMock.mockResolvedValue({ ok: false, json: async () => ({ error: "weak_password" }) });
		renderPage("/reset-password?token=secret-tok");
		await submitPasswords("hunter2hunter2");
		await screen.findByRole("alert");

		fetchMock.mockResolvedValue({ ok: true, json: async () => ({}) });
		await submitPasswords("hunter2hunter2");

		await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
		expect(sentBody(1).token).toBe("secret-tok");
	});

	// A fresh link opened in the same tab must win over the stale stash, or the
	// user is silently resetting with a token they did not just click.
	it("prefers a token in the URL over a held one", async () => {
		renderPage("/reset-password?token=old-tok").unmount();
		renderPage("/reset-password?token=new-tok");

		await submitPasswords("hunter2hunter2");

		await waitFor(() => expect(fetchMock).toHaveBeenCalled());
		expect(sentBody(0).token).toBe("new-tok");
	});

	// Handoffs are stamped with the path they were captured on. A device code
	// stashed by /link shares the sessionStorage prefix but not the stamp.
	it("ignores a token stashed on another path", async () => {
		stashCredential("token", "not-mine", "/link");
		renderPage("/reset-password");

		await submitPasswords("hunter2hunter2");

		expect(fetchMock).not.toHaveBeenCalled();
		expect(await screen.findByRole("alert")).toHaveTextContent(/missing its token/iu);
	});
});
