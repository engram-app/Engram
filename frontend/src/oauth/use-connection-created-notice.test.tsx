import { act, render } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useConnectionCreatedNotice } from "./use-connection-created-notice";

function ConnectionCreatedNotice() {
	useConnectionCreatedNotice();
	return null;
}

const { listeners, socketCtor, toastSuccess } = vi.hoisted(() => ({
	listeners: new Set<(p: { client_name: string | null; kind: string }) => void>(),
	socketCtor: vi.fn(),
	toastSuccess: vi.fn(),
}));

vi.mock("phoenix", () => ({ Socket: socketCtor }));
vi.mock("sonner", () => ({ toast: Object.assign(vi.fn(), { success: toastSuccess }) }));
vi.mock("../api/channel", () => ({
	onConnectionCreated: (l: (p: { client_name: string | null; kind: string }) => void) => {
		listeners.add(l);
		return () => listeners.delete(l);
	},
}));

const emit = (p: { client_name: string | null; kind: string }) =>
	act(() => {
		for (const l of listeners) {
			l(p);
		}
	});

describe("useConnectionCreatedNotice", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		listeners.clear();
	});

	it("opens no socket of its own", () => {
		render(<ConnectionCreatedNotice />);
		expect(socketCtor).not.toHaveBeenCalled();
		expect(listeners.size).toBe(1);
	});

	// The sync socket only exists in the vault, so the tab is already there:
	// tell the user, never navigate (a consent, /link or checkout tab has no
	// socket and hears nothing; the email covers it).
	it("names the client and does not move the tab", () => {
		render(<ConnectionCreatedNotice />);
		emit({ client_name: "ChatGPT", kind: "mcp" });
		expect(toastSuccess).toHaveBeenCalledWith("ChatGPT is connected");
	});

	it("falls back to a generic name", () => {
		render(<ConnectionCreatedNotice />);
		emit({ client_name: null, kind: "mcp" });
		expect(toastSuccess).toHaveBeenCalledWith("Your AI tool is connected");
	});

	it("unsubscribes on unmount", () => {
		const { unmount } = render(<ConnectionCreatedNotice />);
		unmount();
		expect(listeners.size).toBe(0);
	});
});
