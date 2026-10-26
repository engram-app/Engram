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

// iOS zooms the page when a focused text field is under 16px, and does not
// zoom back out. A raw <input> whose own attributes carry a bare `text-sm` or
// `text-xs` (no variant prefix such as `md:`) is 14px or less on a phone.
// Use FIELD_TEXT from lib/ui-classes instead.
const SMALL_TEXT_INPUT = /<input\b(?:(?!\/>)[\s\S])*?(?<![\w:-])text-(?:xs|sm)\b/;

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

	test("lib/ui-classes exports the one 16px-on-mobile field text size", () => {
		expect(uiClasses).toMatch(/export const FIELD_TEXT = "text-base md:text-sm";/);
	});

	test("raw text inputs never render under 16px on a phone", () => {
		const offenders = Object.entries(sources)
			.filter(([, src]) => SMALL_TEXT_INPUT.test(src))
			.map(([path]) => path);
		expect(offenders).toEqual([]);
	});
});
