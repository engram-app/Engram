import { beforeEach, describe, expect, it, vi } from "vitest";
import { uploadInParts } from "./chunked-upload";
import { ApiError } from "./client";

const { get, post, putRaw, del } = vi.hoisted(() => ({
	get: vi.fn(),
	post: vi.fn(),
	putRaw: vi.fn(),
	del: vi.fn(),
}));
vi.mock("./client", async () => {
	const actual = await vi.importActual<typeof import("./client")>("./client");
	return { ...actual, api: { get, post, putRaw, del } };
});

const MiB = 1024 * 1024;
const PART = 8 * MiB;
const row = { id: "a1", path: "big.bin" };

function bigFile(size: number) {
	// A sparse-looking File: only its size and slice bounds matter here.
	return new File([new Uint8Array(size)], "big.bin", { type: "application/octet-stream" });
}

function session(parts: number) {
	post.mockImplementation((path: string) =>
		path === "/attachment-uploads"
			? Promise.resolve({ upload_id: "u1", part_size: PART, part_count: parts })
			: Promise.resolve({ attachment: row }),
	);
}

beforeEach(() => {
	for (const m of [get, post, putRaw, del]) {
		m.mockReset();
	}
	putRaw.mockResolvedValue({});
	del.mockResolvedValue(undefined);
});

describe("uploadInParts", () => {
	it("sends a 20 MiB file as three slices in order, then completes", async () => {
		session(3);
		const file = bigFile(20 * MiB);
		const out = await uploadInParts(file, "big.bin", { backoffMs: 0 });

		expect(post).toHaveBeenNthCalledWith(
			1,
			"/attachment-uploads",
			expect.objectContaining({ path: "big.bin", size_bytes: 20 * MiB }),
			expect.anything(),
		);
		const sizes = putRaw.mock.calls.map((c) => [c[0], (c[1] as Blob).size]);
		expect(sizes).toEqual([
			["/attachment-uploads/u1/parts/1", PART],
			["/attachment-uploads/u1/parts/2", PART],
			["/attachment-uploads/u1/parts/3", 4 * MiB],
		]);
		expect(post).toHaveBeenLastCalledWith(
			"/attachment-uploads/u1/complete",
			undefined,
			expect.anything(),
		);
		expect(out).toEqual({ attachment: row });
	});

	it("reports progress after each part", async () => {
		session(3);
		const onProgress = vi.fn();
		await uploadInParts(bigFile(20 * MiB), "big.bin", { backoffMs: 0, onProgress });
		expect(onProgress.mock.calls).toEqual([
			[PART, 20 * MiB],
			[2 * PART, 20 * MiB],
			[20 * MiB, 20 * MiB],
		]);
	});

	it("retries a failed part after a status check, skipping parts the server holds", async () => {
		session(3);
		putRaw
			.mockResolvedValueOnce({})
			.mockRejectedValueOnce(new TypeError("network"))
			.mockResolvedValue({});
		get.mockResolvedValue({ done: [1], part_count: 3, part_size: PART });

		await uploadInParts(bigFile(20 * MiB), "big.bin", { backoffMs: 0 });

		expect(get).toHaveBeenCalledWith("/attachment-uploads/u1");
		// part 1, part 2 (fails), part 2 again, part 3
		expect(putRaw.mock.calls.map((c) => c[0])).toEqual([
			"/attachment-uploads/u1/parts/1",
			"/attachment-uploads/u1/parts/2",
			"/attachment-uploads/u1/parts/2",
			"/attachment-uploads/u1/parts/3",
		]);
	});

	it("does not resend a part the status says landed despite the error", async () => {
		session(2);
		putRaw.mockRejectedValueOnce(new TypeError("network")).mockResolvedValue({});
		get.mockResolvedValue({ done: [1], part_count: 2, part_size: PART });
		await uploadInParts(bigFile(10 * MiB), "big.bin", { backoffMs: 0 });
		expect(putRaw.mock.calls.map((c) => c[0])).toEqual([
			"/attachment-uploads/u1/parts/1",
			"/attachment-uploads/u1/parts/2",
		]);
	});

	it("gives up after 3 retries of one part and aborts the session", async () => {
		session(1);
		putRaw.mockRejectedValue(new ApiError(502, "bad gateway"));
		get.mockResolvedValue({ done: [], part_count: 1, part_size: PART });
		await expect(uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 })).rejects.toThrow();
		expect(putRaw).toHaveBeenCalledTimes(4);
		expect(del).toHaveBeenCalledWith("/attachment-uploads/u1");
	});

	it("does not retry a terminal 4xx", async () => {
		session(2);
		putRaw.mockRejectedValue(new ApiError(422, "bad_part_size"));
		await expect(
			uploadInParts(bigFile(10 * MiB), "big.bin", { backoffMs: 0 }),
		).rejects.toMatchObject({
			status: 422,
		});
		expect(putRaw).toHaveBeenCalledTimes(1);
		expect(del).toHaveBeenCalled();
	});

	it("retries a 503 using retry-after", async () => {
		session(1);
		putRaw
			.mockRejectedValueOnce(new ApiError(503, "rotation_in_progress", 0))
			.mockResolvedValue({});
		get.mockResolvedValue({ done: [], part_count: 1, part_size: PART });
		await uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 10_000 });
		expect(putRaw).toHaveBeenCalledTimes(2);
	});

	it("sends DELETE and rejects when aborted", async () => {
		session(2);
		const ctl = new AbortController();
		putRaw.mockImplementation(() => {
			ctl.abort();
			return Promise.reject(new DOMException("aborted", "AbortError"));
		});
		await expect(
			uploadInParts(bigFile(10 * MiB), "big.bin", { backoffMs: 0, signal: ctl.signal }),
		).rejects.toThrow();
		expect(putRaw).toHaveBeenCalledTimes(1);
		expect(del).toHaveBeenCalledWith("/attachment-uploads/u1");
	});

	it("does not mask the upload error when the best-effort DELETE fails", async () => {
		session(1);
		putRaw.mockRejectedValue(new ApiError(422, "bad_part_size"));
		del.mockRejectedValue(new TypeError("offline"));
		await expect(
			uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 }),
		).rejects.toMatchObject({
			status: 422,
		});
	});
});
