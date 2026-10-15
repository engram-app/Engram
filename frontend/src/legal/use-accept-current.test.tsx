import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../api/client";
import { useAcceptAgreements } from "./use-accept-current";

const { mutate, statusRef } = vi.hoisted(() => ({
	mutate: vi.fn().mockResolvedValue({ version: "2026-05-19", accepted_at: "now" }),
	statusRef: { current: {} as Record<string, unknown> },
}));

vi.mock("../api/queries", () => ({
	useAcceptTerms: () => ({ mutateAsync: mutate, isPending: false }),
	useOnboardingStatus: () => ({ data: statusRef.current, isLoading: false }),
}));

function current(privacy: string) {
	statusRef.current = { current_tos_version: "2026-05-19", current_privacy_version: privacy };
}

afterEach(() =>
	mutate.mockReset().mockResolvedValue({ version: "2026-05-19", accepted_at: "now" }),
);

describe("useAcceptAgreements", () => {
	it("accepts the current versions when this bundle has them", async () => {
		current("2026-10-12");
		const { result } = renderHook(() => useAcceptAgreements());
		await waitFor(() => expect(result.current.ready).toBe(true));
		await act(() => result.current.accept());
		expect(mutate).toHaveBeenCalledWith(
			expect.objectContaining({ tos_version: "2026-05-19", privacy_version: "2026-10-12" }),
		);
	});

	// The backend published a version after this bundle was built. Accept the
	// newest text this bundle can render; the backend takes it if it is at or
	// above the floor.
	it("falls back to the newest bundled version when the current one is missing", async () => {
		current("2026-10-13");
		const { result } = renderHook(() => useAcceptAgreements());
		await waitFor(() => expect(result.current.ready).toBe(true));
		expect(result.current.unavailable).toBe(false);
		await act(() => result.current.accept());
		expect(mutate).toHaveBeenCalledWith(expect.objectContaining({ privacy_version: "2026-10-12" }));
	});

	it("accepts the exact versions it was given, not the current ones", async () => {
		current("2026-10-14");
		const { result } = renderHook(() => useAcceptAgreements({ privacy: "2026-10-12" }));
		await waitFor(() => expect(result.current.ready).toBe(true));
		await act(() => result.current.accept());
		expect(mutate).toHaveBeenCalledWith(expect.objectContaining({ privacy_version: "2026-10-12" }));
	});

	it("is unavailable when nothing renderable is old enough", async () => {
		current("2000-01-01");
		const { result } = renderHook(() => useAcceptAgreements());
		expect(result.current.unavailable).toBe(true);
		expect(result.current.ready).toBe(false);
	});

	// The fallback is below the required floor: the backend refuses it.
	it("becomes unavailable when the backend refuses the version as stale", async () => {
		current("2026-10-13");
		mutate.mockRejectedValueOnce(new ApiError(409, "stale"));
		const { result } = renderHook(() => useAcceptAgreements());
		await waitFor(() => expect(result.current.ready).toBe(true));
		let accepted: boolean | undefined;
		await act(async () => {
			accepted = await result.current.accept();
		});
		expect(accepted).toBe(false);
		expect(result.current.unavailable).toBe(true);
	});
});
