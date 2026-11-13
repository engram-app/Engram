import { act, render, waitFor } from "@testing-library/react";
import { useContext } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "./auth-context";
import LocalAuthProvider from "./local-auth-provider";

const { markBootstrapComplete } = vi.hoisted(() => ({ markBootstrapComplete: vi.fn() }));
vi.mock("./use-bootstrap", () => ({ markBootstrapComplete }));

function json(status: number, body: unknown) {
	return Promise.resolve({ ok: status < 400, status, json: () => Promise.resolve(body) });
}

// Renders the provider and hands back its adapter once the mount-time silent
// refresh (401 here: no session cookie) has settled.
async function renderAdapter(registerStatus: number): Promise<AuthAdapter> {
	vi.stubGlobal(
		"fetch",
		vi.fn((url: string) =>
			url.endsWith("/api/auth/register")
				? json(registerStatus, {
						access_token: "header.eyJleHAiOjk5OTk5OTk5OTl9.sig",
						user: { email: "a@b.com", role: "admin" },
						error: "setup_token_invalid",
					})
				: json(401, { error: "no_refresh_token" }),
		),
	);
	let adapter: AuthAdapter | null = null;
	function Grab() {
		adapter = useContext(AuthContext);
		return null;
	}
	render(
		<LocalAuthProvider>
			<Grab />
		</LocalAuthProvider>,
	);
	await waitFor(() => expect(adapter?.isLoaded).toBe(true));
	return adapter as unknown as AuthAdapter;
}

afterEach(() => {
	vi.unstubAllGlobals();
	vi.clearAllMocks();
});

describe("LocalAuthProvider register", () => {
	// Otherwise the first-run setup token field comes back after sign-out
	// until a reload (the bootstrap flag is cached for the page's life).
	it("closes the cached claim window once the account exists", async () => {
		const adapter = await renderAdapter(201);

		await act(
			() => adapter.register?.("a@b.com", "secret123", undefined, "tok") ?? Promise.resolve(),
		);

		expect(markBootstrapComplete).toHaveBeenCalledTimes(1);
	});

	it("keeps it open when the claim is refused", async () => {
		const adapter = await renderAdapter(403);

		await expect(adapter.register?.("a@b.com", "secret123", undefined, "bad")).rejects.toThrow(
			"setup_token_invalid",
		);

		expect(markBootstrapComplete).not.toHaveBeenCalled();
	});
});
