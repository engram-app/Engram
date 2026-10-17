import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { LOCALES } from "./locales";

// Two hand-copied locale lists live outside the type-checked app: the e2e i18n
// suites (not in tsconfig) and the backend's email locales (Elixir). A locale
// missing from either fails silently: no browser test, or English email.
const frontend = join(__dirname, "..", "..");
const read = (path: string): string => readFileSync(join(frontend, path), "utf8");
const translated = LOCALES.filter((l) => l !== "en");

describe("locale lists outside the app", () => {
	it("e2e i18n suites cover every locale", () => {
		const leaks = read("e2e/support/i18n-leaks.ts");
		const codes = [...leaks.matchAll(/code: "(?<code>[^"]+)"/gu)].map((m) => m.groups?.code);
		const imports = [
			...leaks.matchAll(/from "\.\.\/\.\.\/src\/i18n\/locale\/(?<code>[^"]+)"/gu),
		].map((m) => m.groups?.code);
		expect([...codes].sort()).toEqual([...translated].sort());
		expect([...imports].sort()).toEqual([...translated].sort());
	});

	it("backend email locales match LOCALES", () => {
		const elixir = read("../lib/engram/i18n.ex");
		const list = /@locales ~w\((?<list>[^)]*)\)/u.exec(elixir)?.groups?.list ?? "";
		expect(list.split(/\s+/u).filter(Boolean).sort()).toEqual([...LOCALES].sort());
	});
});
