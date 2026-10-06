import { describe, expect, test } from "vitest";
import uiClasses from "./ui-classes?raw";

const sources = import.meta.glob<string>(
	["/src/**/*.tsx", "!/src/components/ui/**", "!/src/**/*.test.tsx"],
	{
		query: "?raw",
		import: "default",
		eager: true,
	},
);

// A raw <input> whose own attributes (up to its closing "/>") hand-roll the
// boxed look. Chromeless inputs (border-0), checkboxes, radios and file inputs
// don't use `border-input`, so they never match.
const ADHOC_BOXED_INPUT = /<input\b(?:(?!\/>)[\s\S])*?\bborder-input\b/;

describe("control height", () => {
	test("lib/ui-classes does not export a second input style", () => {
		expect(uiClasses).not.toMatch(/export const (?:fieldInput|inputClass)\b/);
	});

	test("boxed text fields use the shared <Input>, not a hand-styled <input>", () => {
		const offenders = Object.entries(sources)
			.filter(([, src]) => ADHOC_BOXED_INPUT.test(src))
			.map(([path]) => path);
		expect(offenders).toEqual([]);
	});
});
