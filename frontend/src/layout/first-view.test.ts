import { QueryClient } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "../api/client";
import { preloadNoteChunks } from "../viewer/note-chunks";
import { prefetchFirstView } from "./first-view";

vi.mock("../api/client", () => ({ api: { get: vi.fn(async () => ({})) } }));
vi.mock("../viewer/note-chunks", () => ({ preloadNoteChunks: vi.fn() }));

const get = vi.mocked(api.get);

beforeEach(() => {
	get.mockClear();
	vi.mocked(preloadNoteChunks).mockClear();
});

// The first screen used to wait on /bootstrap, then the tree, then the note,
// in series. These start alongside /bootstrap instead.
describe("prefetchFirstView", () => {
	it("starts the tree, the note and the note code for a note URL", () => {
		const qc = new QueryClient();
		prefetchFirstView(qc, "/v/my-vault/n-1", "vault-1");
		expect(get.mock.calls.map(([url]) => url).sort()).toEqual(["/notes/by-id/n-1", "/vault/tree"]);
		expect(preloadNoteChunks).toHaveBeenCalledOnce();
		expect(qc.getQueryState(["note", "vault-1", "n-1"])?.fetchStatus).toBe("fetching");
		expect(qc.getQueryState(["vault-tree", "vault-1"])?.fetchStatus).toBe("fetching");
	});

	it("starts only the tree off a note URL", () => {
		const qc = new QueryClient();
		prefetchFirstView(qc, "/v/my-vault", "vault-1");
		expect(get.mock.calls.map(([url]) => url)).toEqual(["/vault/tree"]);
		expect(preloadNoteChunks).not.toHaveBeenCalled();
	});

	it("does nothing outside a vault, or with no vault remembered yet", () => {
		prefetchFirstView(new QueryClient(), "/settings", "vault-1");
		prefetchFirstView(new QueryClient(), "/v/my-vault/n-1", null);
		expect(get).not.toHaveBeenCalled();
		expect(preloadNoteChunks).not.toHaveBeenCalled();
	});
});
