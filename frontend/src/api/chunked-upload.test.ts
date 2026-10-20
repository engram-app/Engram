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

	it("reports each retry through onRetry, with the error that caused it", async () => {
		session(1);
		const err = new ApiError(503, "rotation_in_progress", 0);
		putRaw.mockRejectedValueOnce(err).mockResolvedValue({});
		get.mockResolvedValue({ done: [], part_count: 1, part_size: PART });
		const onRetry = vi.fn();
		await uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0, onRetry });
		expect(onRetry).toHaveBeenCalledTimes(1);
		expect(onRetry).toHaveBeenCalledWith(err);
	});

	it("does not call onRetry for a terminal failure", async () => {
		session(1);
		putRaw.mockRejectedValue(new ApiError(403, "forbidden"));
		const onRetry = vi.fn();
		await expect(
			uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0, onRetry }),
		).rejects.toThrow();
		expect(onRetry).not.toHaveBeenCalled();
	});

	it("retries a start refused 429 too_many_uploads, using retry-after", async () => {
		session(1);
		post.mockRejectedValueOnce(new ApiError(429, "too_many_uploads", 0));
		const out = await uploadInParts(bigFile(PART), "big.bin", { backoffMs: 10_000 });
		expect(post.mock.calls.filter((c) => c[0] === "/attachment-uploads")).toHaveLength(2);
		expect(out).toEqual({ attachment: row });
	});

	it("does not resend a start that failed any other way", async () => {
		for (const err of [new ApiError(415, "extension_not_allowed"), new TypeError("network")]) {
			post.mockReset();
			post.mockRejectedValue(err);
			await expect(uploadInParts(bigFile(PART), "big.bin", { backoffMs: 0 })).rejects.toBe(err);
			// A lost answer may have opened a session; a resend would hold a second slot.
			expect(post).toHaveBeenCalledTimes(1);
		}
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

	describe("complete", () => {
		const completeCalls = () => post.mock.calls.filter((c) => String(c[0]).endsWith("/complete"));

		it("on 409 missing_parts, re-sends exactly the missing part and completes again", async () => {
			let completes = 0;
			post.mockImplementation((path: string) => {
				if (path === "/attachment-uploads") {
					return Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 2 });
				}
				completes += 1;
				return completes === 1
					? Promise.reject(new ApiError(409, "missing_parts"))
					: Promise.resolve({ attachment: row });
			});
			get.mockResolvedValue({ done: [1], part_count: 2, part_size: PART });

			const out = await uploadInParts(bigFile(10 * MiB), "big.bin", { backoffMs: 0 });

			expect(out).toEqual({ attachment: row });
			expect(putRaw.mock.calls.map((c) => c[0])).toEqual([
				"/attachment-uploads/u1/parts/1",
				"/attachment-uploads/u1/parts/2",
				"/attachment-uploads/u1/parts/2",
			]);
			expect(completeCalls()).toHaveLength(2);
			expect(del).not.toHaveBeenCalled();
		});

		it("on a network error, re-syncs and completes again without sending DELETE", async () => {
			let completes = 0;
			post.mockImplementation((path: string) => {
				if (path === "/attachment-uploads") {
					return Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 1 });
				}
				completes += 1;
				return completes === 1
					? Promise.reject(new TypeError("network"))
					: Promise.resolve({ attachment: row });
			});
			get.mockResolvedValue({ done: [1], part_count: 1, part_size: PART });

			await uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 });

			expect(completeCalls()).toHaveLength(2);
			expect(putRaw).toHaveBeenCalledTimes(1);
			expect(del).not.toHaveBeenCalled();
		});

		it("does not DELETE when every complete attempt ended unknown", async () => {
			post.mockImplementation((path: string) =>
				path === "/attachment-uploads"
					? Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 1 })
					: Promise.reject(new TypeError("network")),
			);
			get.mockRejectedValue(new TypeError("network"));
			await expect(uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 })).rejects.toThrow();
			expect(del).not.toHaveBeenCalled();
		});

		// The first complete committed but its response was lost; a retry that
		// 404s must not be reported until the status check has had its say.
		it("after an unknown outcome, a 404 on the retry defers to a final status check", async () => {
			let completes = 0;
			post.mockImplementation((path: string) => {
				if (path === "/attachment-uploads") {
					return Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 1 });
				}
				completes += 1;
				if (completes === 1) {
					return Promise.reject(new TypeError("network"));
				}
				return completes === 2
					? Promise.reject(new ApiError(404, "not_found"))
					: Promise.resolve({ attachment: row });
			});
			get
				.mockResolvedValueOnce({ done: [1], part_count: 1, part_size: PART, completed: false })
				.mockResolvedValue({ done: [1], part_count: 1, part_size: PART, completed: true });

			const out = await uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 });

			expect(out).toEqual({ attachment: row });
			expect(get).toHaveBeenCalledTimes(2);
			expect(completeCalls()).toHaveLength(3);
			expect(del).not.toHaveBeenCalled();
		});

		it("a 404 that the final status check confirms is reported, once", async () => {
			let completes = 0;
			post.mockImplementation((path: string) => {
				if (path === "/attachment-uploads") {
					return Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 1 });
				}
				completes += 1;
				return completes === 1
					? Promise.reject(new TypeError("network"))
					: Promise.reject(new ApiError(404, "not_found"));
			});
			get.mockResolvedValue({ done: [1], part_count: 1, part_size: PART, completed: false });

			await expect(
				uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 }),
			).rejects.toMatchObject({ status: 404 });
			expect(completeCalls()).toHaveLength(3);
		});

		it("a status with completed: true resolves by calling complete once more", async () => {
			let completes = 0;
			post.mockImplementation((path: string) => {
				if (path === "/attachment-uploads") {
					return Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 1 });
				}
				completes += 1;
				// 524: the edge gave up on a complete that went on to commit.
				return completes === 1
					? Promise.reject(new ApiError(524, "timeout"))
					: Promise.resolve({ attachment: row });
			});
			get.mockResolvedValue({ done: [], part_count: 1, part_size: PART, completed: true });

			const out = await uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 });

			expect(out).toEqual({ attachment: row });
			expect(completeCalls()).toHaveLength(2);
			// completed wins over `done`: no part is sent again.
			expect(putRaw).toHaveBeenCalledTimes(1);
			expect(del).not.toHaveBeenCalled();
		});

		it("DELETEs after a definite terminal refusal on complete", async () => {
			post.mockImplementation((path: string) =>
				path === "/attachment-uploads"
					? Promise.resolve({ upload_id: "u1", part_size: PART, part_count: 1 })
					: Promise.reject(new ApiError(422, "bad")),
			);
			await expect(
				uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 }),
			).rejects.toMatchObject({
				status: 422,
			});
			expect(del).toHaveBeenCalledWith("/attachment-uploads/u1");
		});
	});

	it("retries a transient 5xx on the status check instead of aborting", async () => {
		session(1);
		putRaw.mockRejectedValueOnce(new TypeError("network")).mockResolvedValue({});
		get
			.mockRejectedValueOnce(new ApiError(500, "boom"))
			.mockResolvedValue({ done: [], part_count: 1, part_size: PART });
		await uploadInParts(bigFile(PART + 1), "big.bin", { backoffMs: 0 });
		expect(get).toHaveBeenCalledTimes(2);
		expect(putRaw).toHaveBeenCalledTimes(2);
	});

	it("stops waiting for a retry as soon as the signal aborts", async () => {
		session(1);
		putRaw.mockRejectedValue(new TypeError("network"));
		const ctl = new AbortController();
		const started = Date.now();
		const run = uploadInParts(bigFile(PART + 1), "big.bin", {
			backoffMs: 60_000,
			signal: ctl.signal,
		});
		setTimeout(() => ctl.abort(), 20);
		await expect(run).rejects.toMatchObject({ name: "AbortError" });
		expect(Date.now() - started).toBeLessThan(5000);
		expect(del).toHaveBeenCalledWith("/attachment-uploads/u1");
	});
});
