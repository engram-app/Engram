import { expect, it } from "vitest";
import { msg } from "./msg";
import { Trans } from "./trans";
import { englishT, englishTn } from "./translate";

// Type-level gate, checked by tsc: a key the scanner cannot read (a widened
// `string`) must not compile. Each @ts-expect-error line IS the assertion: tsc
// fails if the call below it ever starts compiling.
it("rejects a widened string key and accepts literals and msg() keys", () => {
	const dynamic: string = "Save";
	const forms: { one: string; other: string } = { one: "{count} a", other: "{count} b" };
	const t = englishT;
	const tn = englishTn;

	// @ts-expect-error a plain string is invisible to the key scanner
	t(dynamic);
	// @ts-expect-error a template literal is a widened string too
	t(`Hello ${dynamic}`);
	// @ts-expect-error a widened plural object is invisible to the scanner
	tn(forms, 2);
	// @ts-expect-error marking a variable makes a key no catalog holds
	msg(dynamic);
	const pick = dynamic.length > 3;
	// @ts-expect-error a union of literals reaches the scanner as neither
	t(pick ? "Foo" : "Bar");

	expect(t("Save")).toBe("Save");
	expect(t(msg("Save"))).toBe("Save");
	expect(tn({ one: "{count} a", other: "{count} b" }, 2)).toBe("2 b");
});

it("rejects a widened string as the Trans text", () => {
	const dynamic: string = "Save";
	// Never called: a component outside render would throw on its hook. tsc checks it.
	const check = () => [
		// @ts-expect-error a plain string is invisible to the key scanner
		Trans({ text: dynamic, slots: {} }),
		Trans({ text: "Save {b}", slots: {} }),
		Trans({ text: msg("Save {b}"), slots: {} }),
	];
	expect(typeof check).toBe("function");
});
