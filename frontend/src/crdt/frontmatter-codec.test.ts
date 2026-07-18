import { describe, expect, test } from "vitest";
import { emitFrontmatter, parseFrontmatter, projectNote, splitFrontmatter } from "./frontmatter-codec";
import { VECTORS } from "./frontmatter-codec.vectors";

describe("frontmatter-codec vectors", () => {
	for (const v of VECTORS) {
		test(`split+parse: ${v.name}`, () => {
			const { fmBlock, body } = splitFrontmatter(v.markdown);
			expect(body).toBe(v.body);
			const parsed = fmBlock === null ? { order: [], values: {} } : parseFrontmatter(fmBlock);
			expect(parsed).not.toBeNull();
			expect(parsed?.order).toEqual(v.order);
			expect(parsed?.values).toEqual(v.values);
		});

		test(`round-trip re-projects stable order: ${v.name}`, () => {
			const { fmBlock, body } = splitFrontmatter(v.markdown);
			const parsed = fmBlock === null ? { order: [], values: {} } : parseFrontmatter(fmBlock);
			expect(parsed).not.toBeNull();
			const projected = projectNote(parsed!.order, parsed!.values, body);
			// Re-splitting the projection yields the same structured form (idempotent).
			const again = splitFrontmatter(projected);
			const reparsed = again.fmBlock === null ? { order: [], values: {} } : parseFrontmatter(again.fmBlock);
			expect(reparsed?.order).toEqual(v.order);
			expect(reparsed?.values).toEqual(v.values);
			expect(again.body).toBe(v.body);
		});
	}

	test("emitFrontmatter re-renders a degraded key verbatim from raws", () => {
		const out = emitFrontmatter(["good", "bad"], { good: JSON.stringify("x") }, { bad: "bad: [unclosed\n" });
		expect(out).toContain("bad: [unclosed\n");
		expect(out).toContain("good:");
	});

	test("parseFrontmatter returns null on invalid YAML", () => {
		expect(parseFrontmatter("a: [unclosed\n")).toBeNull();
	});
});
