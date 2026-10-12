import { describe, expect, expectTypeOf, it } from "vitest";
import { msg } from "./msg";
import { englishT, englishTn, interpolate, type Translate } from "./translate";
import { type MsgKey, type UIText, untranslated } from "./ui-text";

describe("UIText", () => {
	it("is not assignable from a plain string, so raw copy fails tsc", () => {
		expectTypeOf<string>().not.toMatchTypeOf<UIText>();
		expectTypeOf<"Save">().not.toMatchTypeOf<UIText>();
	});

	it("still reads as a string wherever one is expected", () => {
		expectTypeOf<UIText>().toMatchTypeOf<string>();
	});

	it("is what the translators return", () => {
		expectTypeOf<ReturnType<Translate>>().toEqualTypeOf<UIText>();
		expectTypeOf(englishT("Save")).toEqualTypeOf<UIText>();
		expectTypeOf(
			englishTn({ one: "{count} file", other: "{count} files" }, 2),
		).toEqualTypeOf<UIText>();
		expectTypeOf(interpolate("Hi {name}", { name: "x" })).toEqualTypeOf<UIText>();
	});

	it("is not what msg() returns: a marked key is not translated yet", () => {
		expectTypeOf(msg("Settings")).not.toMatchTypeOf<UIText>();
	});

	it("msg() returns a MsgKey, which a raw literal is not", () => {
		expectTypeOf(msg("Settings")).toEqualTypeOf<MsgKey>();
		expectTypeOf<"Settings">().not.toMatchTypeOf<MsgKey>();
		expectTypeOf<MsgKey>().not.toMatchTypeOf<UIText>();
		expectTypeOf<MsgKey>().toMatchTypeOf<string>();
	});
});

describe("untranslated", () => {
	it("passes text through unchanged", () => {
		expect(untranslated("note title.md")).toBe("note title.md");
		expectTypeOf(untranslated("x")).toEqualTypeOf<UIText>();
	});
});
