import { describe, expect, test } from "vitest";
import { escapeNonMathDollars, INLINE_MATH } from "./math-delimiters";

// `$…$` is inline math only by pandoc's rules, which is what keeps prices from
// reading as math: the opening `$` is followed by a non-space, the closing one
// is preceded by a non-space and NOT followed by a digit, and `\$` is a literal
// dollar. Without them, `**$175k base** … **$150k base**` was one math span that
// swallowed the bold markers.
const spans = (s: string) => Array.from(s.matchAll(INLINE_MATH), (m) => m[0]);

describe("INLINE_MATH", () => {
	test("matches ordinary inline math", () => {
		expect(spans("so $x^2$ and $a$ done")).toEqual(["$x^2$", "$a$"]);
	});

	test("two prices are not math (the closing $ is followed by a digit)", () => {
		expect(spans("$20 and $30")).toEqual([]);
	});

	test("the user's sentence is not math", () => {
		expect(
			spans("You ended at **$175k base at Gala**. Your floor is **$150k base** (confirmed)."),
		).toEqual([]);
	});

	test("no space just inside either delimiter", () => {
		expect(spans("$ x$")).toEqual([]);
		expect(spans("$x $")).toEqual([]);
	});

	test("an escaped dollar neither opens nor closes", () => {
		expect(spans("\\$5 and $x$")).toEqual(["$x$"]);
		expect(spans("$x\\$")).toEqual([]);
	});

	test("a price followed by real math still finds the math", () => {
		expect(spans("costs $5 and $x$ here")).toEqual(["$x$"]);
	});

	test("does not span lines", () => {
		expect(spans("$a\nb$")).toEqual([]);
	});
});

describe("escapeNonMathDollars", () => {
	test("escapes the dollars of a price sentence so they render literally", () => {
		expect(
			escapeNonMathDollars(
				"You ended at **$175k base at Gala**. Your floor is **$150k base** (confirmed).",
			),
		).toBe("You ended at **\\$175k base at Gala**. Your floor is **\\$150k base** (confirmed).");
	});

	test("leaves real math alone", () => {
		expect(escapeNonMathDollars("energy $E=mc^2$ and $$x$$ here")).toBe(
			"energy $E=mc^2$ and $$x$$ here",
		);
	});

	test("escapes a price next to real math, not the math", () => {
		expect(escapeNonMathDollars("costs $5 and $x$ ok")).toBe("costs \\$5 and $x$ ok");
	});

	test("leaves already-escaped dollars alone", () => {
		expect(escapeNonMathDollars("pay \\$5 now")).toBe("pay \\$5 now");
	});

	test("leaves fenced code untouched", () => {
		const md = "```\nprice = $5 and $10\n```\n";
		expect(escapeNonMathDollars(md)).toBe(md);
	});

	test("leaves inline code untouched", () => {
		expect(escapeNonMathDollars("use `$5` here and $7")).toBe("use `$5` here and \\$7");
	});

	test("leaves a multi-line $$ block untouched", () => {
		const md = "$$\n\\begin{vmatrix}a & b\\\\\nc & d\\end{vmatrix}=ad-bc\n$$\n";
		expect(escapeNonMathDollars(md)).toBe(md);
	});

	test("text with no dollars is returned as is", () => {
		expect(escapeNonMathDollars("plain **bold** text")).toBe("plain **bold** text");
	});
});
