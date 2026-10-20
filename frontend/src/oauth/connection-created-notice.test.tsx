import { act, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "../auth/auth-context";
import { ConnectionCreatedNotice } from "./connection-created-notice";

const { channelHandlers, socketCtor, socketDisconnect, toastSuccess } = vi.hoisted(() => {
	const channelHandlers: Record<string, (payload: unknown) => void> = {};
	const channelMock = {
		on: (event: string, cb: (payload: unknown) => void) => {
			channelHandlers[event] = cb;
		},
		join: () => ({ receive: () => ({}) }),
	};
	const socketDisconnect = vi.fn();
	const socketCtor = vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			channel: vi.fn(() => channelMock),
			disconnect: socketDisconnect,
		});
	});
	return { channelHandlers, socketCtor, socketDisconnect, toastSuccess: vi.fn() };
});

vi.mock("phoenix", () => ({ Socket: socketCtor }));
vi.mock("sonner", () => ({ toast: Object.assign(vi.fn(), { success: toastSuccess }) }));
vi.mock("../api/queries", () => ({ useMe: () => ({ data: { id: "u1" } }) }));

const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: async () => "tok",
	logout: async () => {},
	hasBuiltInUI: false,
};

function Where() {
	return <output data-testid="where">{useLocation().pathname}</output>;
}

async function mountAt(path: string) {
	const view = render(
		<AuthContext.Provider value={authAdapter}>
			<MemoryRouter initialEntries={[path]}>
				<ConnectionCreatedNotice />
				<Routes>
					<Route path="*" element={<Where />} />
				</Routes>
			</MemoryRouter>
		</AuthContext.Provider>,
	);
	// The socket opens after the token resolves.
	await act(async () => {});
	return view;
}

interface ToastOptions {
	action?: { label: string; onClick: () => void };
	cancel?: { label: string; onClick: () => void };
	onAutoClose?: () => void;
	duration?: number;
}

function lastToast(): [string, ToastOptions | undefined] {
	const call = toastSuccess.mock.calls.at(-1);
	if (!call) {
		throw new Error("no toast");
	}
	return call as [string, ToastOptions | undefined];
}

describe("ConnectionCreatedNotice", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		for (const k of Object.keys(channelHandlers)) {
			delete channelHandlers[k];
		}
	});

	it("listens on the user's channel", async () => {
		await mountAt("/onboard/vault");
		expect(socketCtor).toHaveBeenCalledTimes(1);
		expect(channelHandlers.connection_created).toBeTypeOf("function");
	});

	it("names the client and offers the vault, advancing on its own", async () => {
		await mountAt("/onboard/vault");
		act(() => channelHandlers.connection_created?.({ client_name: "ChatGPT", kind: "mcp" }));

		const [message, opts = {}] = lastToast();
		expect(message).toBe("ChatGPT is connected");
		expect(opts.action?.label).toBe("Continue to your vault");
		expect(opts.cancel?.label).toBe("Stay here");
		expect(opts.duration).toBe(3000);

		act(() => opts.onAutoClose?.());
		expect(screen.getByTestId("where")).toHaveTextContent(/^\/$/u);
	});

	it("the button goes at once", async () => {
		await mountAt("/link");
		act(() => channelHandlers.connection_created?.({ client_name: "ChatGPT", kind: "mcp" }));
		act(() => lastToast()[1]?.action?.onClick());
		expect(screen.getByTestId("where")).toHaveTextContent(/^\/$/u);
	});

	// Stay here dismisses the toast, which is not an auto-close: no advance.
	it("Stay here cancels the advance", async () => {
		await mountAt("/link");
		act(() => channelHandlers.connection_created?.({ client_name: "ChatGPT", kind: "mcp" }));
		act(() => lastToast()[1]?.cancel?.onClick());
		expect(screen.getByTestId("where")).toHaveTextContent("/link");
	});

	it("falls back to a generic name when the client has none", async () => {
		await mountAt("/link");
		act(() => channelHandlers.connection_created?.({ client_name: null, kind: "mcp" }));
		expect(lastToast()[0]).toBe("Your AI tool is connected");
	});

	// Already in the vault: never pull the user off the note they are on.
	it("only tells a tab already in the vault", async () => {
		await mountAt("/v/notes/abc");
		act(() => channelHandlers.connection_created?.({ client_name: "Claude", kind: "mcp" }));
		const [message, opts] = lastToast();
		expect(message).toBe("Claude is connected");
		expect(opts?.action).toBeUndefined();
		expect(opts?.onAutoClose).toBeUndefined();
	});

	it("closes its socket on unmount", async () => {
		const { unmount } = await mountAt("/link");
		unmount();
		expect(socketDisconnect).toHaveBeenCalledTimes(1);
	});
});
