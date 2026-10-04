import { describe, expect, it } from "vitest";
import { interpolate, translate, translatePlural } from "./translate";

const EN_FILES = { one: "{count} file", other: "{count} files" };

describe("interpolate", () => {
	it("fills named placeholders", () => {
		expect(interpolate("Hi {name}", { name: "Todd" })).toBe("Hi Todd");
	});
	it("leaves an unknown placeholder visible", () => {
		expect(interpolate("Hi {name}", {})).toBe("Hi {name}");
	});
	it("returns the template when there are no vars", () => {
		expect(interpolate("Hi {name}")).toBe("Hi {name}");
	});
});

describe("translate", () => {
	it("uses the catalog entry", () => {
		expect(translate({ "Hello {n}": "Hallo {n}" }, "Hello {n}", { n: 1 })).toBe("Hallo 1");
	});
	it("falls through to English on a missing key", () => {
		expect(translate({}, "Hello {n}", { n: 1 })).toBe("Hello 1");
	});
	it("ignores a plural entry stored under a string key", () => {
		expect(translate({ Hello: { other: "x" } }, "Hello")).toBe("Hello");
	});
});

describe("translatePlural", () => {
	it("falls through to English forms with English plural rules", () => {
		expect(translatePlural({}, "ru", EN_FILES, 1)).toBe("1 file");
		expect(translatePlural({}, "ru", EN_FILES, 2)).toBe("2 files");
	});
	it("uses Russian one/few/many", () => {
		const catalog = {
			"{count} files": {
				one: "{count} файл",
				few: "{count} файла",
				many: "{count} файлов",
				other: "{count} файла",
			},
		};
		expect(translatePlural(catalog, "ru", EN_FILES, 1)).toBe("1 файл");
		expect(translatePlural(catalog, "ru", EN_FILES, 3)).toBe("3 файла");
		expect(translatePlural(catalog, "ru", EN_FILES, 5)).toBe("5 файлов");
		expect(translatePlural(catalog, "ru", EN_FILES, 21)).toBe("21 файл");
	});
	it("handles a single-form language", () => {
		const catalog = { "{count} files": { other: "{count}個のファイル" } };
		expect(translatePlural(catalog, "ja", EN_FILES, 1)).toBe("1個のファイル");
		expect(translatePlural(catalog, "ja", EN_FILES, 0)).toBe("0個のファイル");
	});
	it("does not let vars override count", () => {
		expect(translatePlural({}, "en", EN_FILES, 2, { count: 99 })).toBe("2 files");
	});
});
