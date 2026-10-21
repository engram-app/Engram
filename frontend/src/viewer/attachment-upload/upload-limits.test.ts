import { describe, expect, test } from "vitest";
import { screenUploads } from "./upload-limits";

const f = (name: string, size: number) => new File([new Uint8Array(size)], name);
const MB = 1024 * 1024;

describe("screenUploads", () => {
	test("no limits lets everything through", () => {
		const files = [f("a", 5 * MB)];
		expect(screenUploads(files, { maxFileBytes: null, storageCap: null, usedBytes: 0 })).toEqual({
			allowed: files,
			tooLarge: [],
			noRoom: [],
		});
	});

	test("a file over the per-file limit is refused", () => {
		const ok = f("ok", MB);
		const big = f("big", 11 * MB);
		const r = screenUploads([ok, big], { maxFileBytes: 10 * MB, storageCap: null, usedBytes: 0 });
		expect(r.allowed).toEqual([ok]);
		expect(r.tooLarge).toEqual([big]);
	});

	test("files that would overfill storage are refused, in order", () => {
		const a = f("a", 4 * MB);
		const b = f("b", 4 * MB);
		const c = f("c", MB);
		const r = screenUploads([a, b, c], {
			maxFileBytes: null,
			storageCap: 10 * MB,
			usedBytes: 5 * MB,
		});
		expect(r.allowed).toEqual([a, c]);
		expect(r.noRoom).toEqual([b]);
	});

	test("a too-large file does not use up storage room", () => {
		const big = f("big", 20 * MB);
		const small = f("small", 2 * MB);
		const r = screenUploads([big, small], {
			maxFileBytes: 10 * MB,
			storageCap: 10 * MB,
			usedBytes: 7 * MB,
		});
		expect(r).toEqual({ allowed: [small], tooLarge: [big], noRoom: [] });
	});
});
