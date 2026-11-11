import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "vitest";
import { splitFrontmatter } from "./frontmatter-codec";

// The one fence rule's table, the same file native/engram_core's Rust tests
// and test/engram/native/frontmatter_fence_test.exs assert, so this TS copy
// cannot drift from the backend.
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

test.each(CASES)("splitFrontmatter follows the shared table: $name", ({ input, block, body }) => {
	expect(splitFrontmatter(input)).toEqual({ fmBlock: block, body });
});
