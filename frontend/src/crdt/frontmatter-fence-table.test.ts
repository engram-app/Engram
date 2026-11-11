import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { splitFrontmatter, splitFrontmatterTs } from "./frontmatter-codec";
import { loadFenceWasm, resetFenceWasm } from "./frontmatter-fence";

// The one fence rule's table, also asserted by native/engram_core's Rust
// tests and test/engram/native/frontmatter_fence_test.exs.
interface Case {
	name: string;
	input: string;
	block: string | null;
	body: string;
}
const CASES: Case[] = JSON.parse(
	readFileSync(
		join(__dirname, "../../../native/engram_core/fixtures/frontmatter_fence.json"),
		"utf8",
	),
);

const wasmBytes = readFileSync(join(__dirname, "frontmatter-fence.wasm"));
const fromBytes = async () => (await WebAssembly.instantiate(wasmBytes)).instance;

afterEach(resetFenceWasm);

describe("the shared fence table", () => {
	test.each(CASES)("TS path: $name", ({ input, block, body }) => {
		expect(splitFrontmatterTs(input)).toEqual({ fmBlock: block, body });
	});

	test.each(CASES)("wasm path: $name", async ({ input, block, body }) => {
		await loadFenceWasm(fromBytes);
		expect(splitFrontmatter(input)).toEqual({ fmBlock: block, body });
	});
});

describe("the wasm split", () => {
	test("offsets survive multi-byte text and a note past the initial memory", async () => {
		await loadFenceWasm(fromBytes);
		const note = `---\ntitle: 日本 🎉\n---\n${"é€".repeat(200_000)}`;
		expect(splitFrontmatter(note)).toEqual(splitFrontmatterTs(note));
		expect(splitFrontmatter(note).fmBlock).toBe("title: 日本 🎉\n");
	});

	test("a lone surrogate takes the TS path, unchanged", async () => {
		await loadFenceWasm(fromBytes);
		const note = "---\na: \uD800\n---\nb\uDC00";
		expect(splitFrontmatter(note)).toEqual({ fmBlock: "a: \uD800\n", body: "b\uDC00" });
	});

	test("a module that fails the self-check is not used", async () => {
		const broken = async () => {
			const { instance } = await WebAssembly.instantiate(wasmBytes);
			const ex = instance.exports;
			return { exports: { ...ex, fm_split: () => 0 } };
		};
		await expect(loadFenceWasm(broken)).rejects.toThrow(/self-check/);
		expect(splitFrontmatter("---\r\na: 1\r\n---\r\nb")).toEqual({ fmBlock: "a: 1\r\n", body: "b" });
	});
});
