import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetNoteChangeBatch, handleNoteChanged } from "./channel";
import { useSyncManifest } from "./queries";

// Real cache wiring: a real QueryClient + the real channel handler + the real
// useSyncManifest hook. Only the HTTP layer and the active-vault id are mocked.
// This is the staleness bug's exact seam — ["syncManifest", vaultId] had zero
// invalidation sites, so a note created/renamed mid-session never reached the
// [[ autocomplete list (note-page.tsx derives it as manifest.notes.map(path))
// until an incidental remount/refocus refetched it.

const { get } = vi.hoisted(() => ({ get: vi.fn() }));

vi.mock("./client", async () => {
	const actual = await vi.importActual<typeof import("./client")>("./client");
	return { ...actual, api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() } };
});

vi.mock("./active-vault", async () => {
	const actual = await vi.importActual<typeof import("./active-vault")>("./active-vault");
	return { ...actual, useActiveVaultId: () => "42" };
});

// The [[ autocomplete candidate list, exactly as note-page.tsx derives it.
function useCompletionPaths(): string[] {
	const { data: manifest } = useSyncManifest();
	return manifest?.notes.map((n) => n.path) ?? [];
}

let qc: QueryClient;
let wrapper: React.FC<{ children: React.ReactNode }>;

beforeEach(() => {
	get.mockReset();
	qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	wrapper = ({ children }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
});

afterEach(() => {
	__resetNoteChangeBatch();
	qc.clear();
});

describe("sync manifest staleness (issue: [[ autocomplete misses new notes)", () => {
	it("a newly created note appears in the completion paths without remount/refocus", async () => {
		get.mockResolvedValue({ notes: [{ id: "n1", path: "a.md" }] });
		const { result } = renderHook(() => useCompletionPaths(), { wrapper });
		await waitFor(() => expect(result.current).toEqual(["a.md"]));

		// The server-side create lands (local echo or another device) — the sync
		// channel delivers note_changed; the NEXT manifest fetch includes the note.
		get.mockResolvedValue({
			notes: [
				{ id: "n1", path: "a.md" },
				{ id: "n2", path: "new-note.md" },
			],
		});
		act(() => {
			handleNoteChanged(
				{ event_type: "upsert", path: "new-note.md", id: "n2", vault_id: "42" },
				qc,
				"42",
			);
		});

		// No remount, no refocus — the invalidation alone must refetch (the
		// coalescing window is 250ms; waitFor spans it).
		await waitFor(() => expect(result.current).toContain("new-note.md"));
	});

	it("a rename updates the completion paths without remount/refocus", async () => {
		get.mockResolvedValue({ notes: [{ id: "n1", path: "old.md" }] });
		const { result } = renderHook(() => useCompletionPaths(), { wrapper });
		await waitFor(() => expect(result.current).toEqual(["old.md"]));

		get.mockResolvedValue({ notes: [{ id: "n1", path: "new.md" }] });
		act(() => {
			handleNoteChanged(
				{ event_type: "upsert", path: "new.md", id: "n1", vault_id: "42" },
				qc,
				"42",
			);
		});

		await waitFor(() => expect(result.current).toEqual(["new.md"]));
	});
});
