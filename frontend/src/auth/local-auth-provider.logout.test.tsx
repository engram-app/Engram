import { act, render } from "@testing-library/react";
import { useContext } from "react";
import { afterEach, expect, it, vi } from "vitest";
import { setApiBase } from "../api/base";
import { type AuthAdapter, AuthContext } from "./auth-context";
import LocalAuthProvider from "./local-auth-provider";

vi.mock("../api/client", () => ({ setTokenGetter: vi.fn() }));
vi.mock("../api/query-client", () => ({ queryClient: {} }));
vi.mock("./use-clear-query-cache-on-user-change", () => ({
	useClearQueryCacheOnUserChange: vi.fn(),
}));
vi.mock("./use-wipe-crdt-on-user-change", () => ({ useWipeCrdtOnUserChange: vi.fn() }));

const payload = btoa(JSON.stringify({ email: "a@example.test", exp: 4_102_444_800 }));
const accessToken = `h.${payload}.s`;

afterEach(() => {
	vi.restoreAllMocks();
	setApiBase("");
});

// /api/auth/logout answers with Clear-Site-Data, which the browser holds open
// until its cache wipe ends (minutes on Android). Self-host logout must not wait.
it("self-host logout signs out at once while /api/auth/logout never settles", async () => {
	setApiBase("https://api.example.test/api");
	const fetchMock = vi
		.spyOn(globalThis, "fetch")
		.mockImplementation((input) =>
			String(input).endsWith("/auth/refresh")
				? Promise.resolve(Response.json({ access_token: accessToken }))
				: new Promise(() => undefined),
		);
	const grabbed: { adapter: AuthAdapter | null } = { adapter: null };
	function Grab() {
		grabbed.adapter = useContext(AuthContext);
		return null;
	}
	render(
		<LocalAuthProvider>
			<Grab />
		</LocalAuthProvider>,
	);
	await vi.waitFor(() => expect(grabbed.adapter?.isSignedIn).toBe(true));

	await act(() => grabbed.adapter?.logout());

	expect(grabbed.adapter?.isSignedIn).toBe(false);
	expect(grabbed.adapter?.user).toBeNull();
	expect(fetchMock).toHaveBeenCalledWith(
		"https://api.example.test/api/auth/logout",
		expect.objectContaining({ method: "POST", credentials: "include", keepalive: true }),
	);
});
