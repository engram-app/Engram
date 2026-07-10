import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { MemoryRouter, Route, Routes } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { useActiveFolder } from "./active-folder";

// Mock useActiveVaultId to a fixed value
vi.mock("../api/active-vault", () => ({
	useActiveVaultId: () => "1",
}));

function wrap(qc: QueryClient, initialPath: string) {
	return ({ children }: { children: ReactNode }) => (
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[initialPath]}>
				<Routes>
					<Route path="/note/:id" element={children} />
					<Route path="/" element={children} />
				</Routes>
			</MemoryRouter>
		</QueryClientProvider>
	);
}

describe("useActiveFolder", () => {
	it("returns the folder of the cached note", () => {
		const qc = new QueryClient();
		qc.setQueryData(["note", "1", "42"], { id: "42", folder: "src", path: "src/a.md" });
		const { result } = renderHook(() => useActiveFolder(), { wrapper: wrap(qc, "/note/42") });
		expect(result.current).toBe("src");
	});

	it('returns "" when no note is cached', () => {
		const qc = new QueryClient();
		const { result } = renderHook(() => useActiveFolder(), { wrapper: wrap(qc, "/note/42") });
		expect(result.current).toBe("");
	});

	it('returns "" when not on a note route (no :id param)', () => {
		const qc = new QueryClient();
		const { result } = renderHook(() => useActiveFolder(), { wrapper: wrap(qc, "/") });
		expect(result.current).toBe("");
	});

	it('returns "" when the cached note\'s folder no longer exists — no resurrection', () => {
		const qc = new QueryClient();
		qc.setQueryData(["note", "1", "42"], {
			id: "42",
			folder: "Untitled folder",
			path: "Untitled folder/n.md",
		});
		// Folder list is loaded, but "Untitled folder" was deleted and is gone.
		qc.setQueryData(["folders", "1"], { folders: [{ id: "k", name: "Keep" }] });
		const { result } = renderHook(() => useActiveFolder(), { wrapper: wrap(qc, "/note/42") });
		expect(result.current).toBe("");
	});

	it("returns the folder when it still exists in the loaded folder list", () => {
		const qc = new QueryClient();
		qc.setQueryData(["note", "1", "42"], { id: "42", folder: "Keep", path: "Keep/n.md" });
		qc.setQueryData(["folders", "1"], { folders: [{ id: "k", name: "Keep" }] });
		const { result } = renderHook(() => useActiveFolder(), { wrapper: wrap(qc, "/note/42") });
		expect(result.current).toBe("Keep");
	});

	it("trusts the note's folder when the folder list has not loaded yet", () => {
		const qc = new QueryClient();
		qc.setQueryData(["note", "1", "42"], {
			id: "42",
			folder: "Deep/Nested",
			path: "Deep/Nested/n.md",
		});
		// No ["folders","1"] seeded → undefined → don't reset (avoid a load-race regression).
		const { result } = renderHook(() => useActiveFolder(), { wrapper: wrap(qc, "/note/42") });
		expect(result.current).toBe("Deep/Nested");
	});
});
