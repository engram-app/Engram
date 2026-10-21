import { describe, expect, test } from "vitest";
import {
	attachmentRenamePath,
	excalidrawTexts,
	fileStem,
	formatBytes,
	opensInline,
	parseCsv,
	previewKind,
} from "./attachment-preview";

describe("previewKind", () => {
	test("routes by mime first", () => {
		expect(previewKind("a/pic.bin", "image/png")).toBe("image");
		expect(previewKind("doc.pdf", "application/pdf")).toBe("pdf");
		expect(previewKind("song.mp3", "audio/mpeg")).toBe("audio");
		expect(previewKind("clip.mp4", "video/mp4")).toBe("video");
		expect(previewKind("data.json", "application/json")).toBe("text");
	});

	test("falls back to the extension when mime is generic", () => {
		expect(previewKind("app.LOG", "application/octet-stream")).toBe("text");
		expect(previewKind("cfg/config.yaml", "")).toBe("text");
		expect(previewKind("table.csv", "application/octet-stream")).toBe("csv");
		expect(previewKind("table.tsv", "text/tab-separated-values")).toBe("csv");
	});

	test("no preview for unknown binaries", () => {
		expect(previewKind("snatchlist.zip", "application/zip")).toBeNull();
		expect(previewKind("noext", "")).toBeNull();
	});
});

describe("opensInline", () => {
	test("only types that cannot run script in our origin", () => {
		expect(opensInline("image/png")).toBe(true);
		expect(opensInline("application/pdf")).toBe(true);
		expect(opensInline("video/mp4")).toBe(true);
		expect(opensInline("image/svg+xml")).toBe(false);
		expect(opensInline("text/html")).toBe(false);
		expect(opensInline("application/xhtml+xml")).toBe(false);
		expect(opensInline("")).toBe(false);
	});
});

describe("parseCsv", () => {
	test("splits rows and cells", () => {
		expect(parseCsv("a,b\n1,2\r\n3,4\n", ",", 10)).toEqual([
			["a", "b"],
			["1", "2"],
			["3", "4"],
		]);
	});

	test("handles quotes, escaped quotes and newlines inside quotes", () => {
		expect(parseCsv('"x, y","say ""hi"""\n"multi\nline",z', ",", 10)).toEqual([
			["x, y", 'say "hi"'],
			["multi\nline", "z"],
		]);
	});

	test("tab delimiter and row cap", () => {
		expect(parseCsv("a\tb\nc\td\ne\tf", "\t", 2)).toEqual([
			["a", "b"],
			["c", "d"],
		]);
	});

	test("empty input", () => {
		expect(parseCsv("", ",", 10)).toEqual([]);
	});
});

describe("formatBytes", () => {
	test("picks a unit", () => {
		expect(formatBytes(0, "en")).toBe("0 byte");
		expect(formatBytes(512, "en")).toBe("512 byte");
		expect(formatBytes(1536, "en")).toBe("1.5 kB");
		expect(formatBytes(10 * 1024 * 1024, "en")).toBe("10 MB");
	});
});

describe("extension-locked rename", () => {
	test("fileStem splits the extension off", () => {
		expect(fileStem("a/report.final.pdf")).toEqual({ stem: "report.final", ext: ".pdf" });
		expect(fileStem("Makefile")).toEqual({ stem: "Makefile", ext: "" });
		expect(fileStem(".env")).toEqual({ stem: ".env", ext: "" });
	});

	test("keeps the folder and the extension", () => {
		expect(attachmentRenamePath("files/a.zip", "b")).toBe("files/b.zip");
		expect(attachmentRenamePath("a.zip", "  b  ")).toBe("b.zip");
	});

	test("a typed matching extension is not doubled", () => {
		expect(attachmentRenamePath("a.zip", "b.ZIP")).toBe("b.zip");
	});

	test("a different typed extension stays part of the name", () => {
		expect(attachmentRenamePath("a.zip", "b.exe")).toBe("b.exe.zip");
	});

	test("null when nothing changes or the name is empty or has a slash", () => {
		expect(attachmentRenamePath("a.zip", "a")).toBeNull();
		expect(attachmentRenamePath("a.zip", "   ")).toBeNull();
		expect(attachmentRenamePath("a.zip", "x/y")).toBeNull();
	});
});

describe("Excalidraw", () => {
	test("a .excalidraw file and the plugin's .excalidraw.md are drawings", () => {
		expect(previewKind("a/Plan.excalidraw", "application/octet-stream")).toBe("excalidraw");
		expect(previewKind("Plan.Excalidraw.md", "text/markdown")).toBe("excalidraw");
		expect(previewKind("Plan.md", "text/markdown")).toBe("text");
	});

	test("pulls the text out of raw JSON", () => {
		const json = JSON.stringify({
			type: "excalidraw",
			elements: [
				{ type: "rectangle" },
				{ type: "text", text: "Hello" },
				{ type: "text", text: "  " },
				{ type: "text", text: "World" },
			],
		});
		expect(excalidrawTexts(json)).toEqual(["Hello", "World"]);
	});

	test("pulls the Text Elements section out of the plugin's markdown", () => {
		const md = [
			"---",
			"excalidraw-plugin: parsed",
			"---",
			"# Text Elements",
			"Hello Excalidraw ^txt1",
			"",
			"Second ^abc",
			"%%",
			"# Drawing",
			"```json",
			"{}",
			"```",
		].join("\n");
		expect(excalidrawTexts(md)).toEqual(["Hello Excalidraw", "Second"]);
	});

	test("anything else yields no text", () => {
		expect(excalidrawTexts("not json")).toEqual([]);
		expect(excalidrawTexts("{}")).toEqual([]);
	});
});
