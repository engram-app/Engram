import { beforeEach, describe, expect, it, test } from "vitest";
import {
	attachmentPartSize,
	captureServerFeatures,
	isBlockedFileName,
	resetServerFeatures,
} from "./server-features";

beforeEach(resetServerFeatures);

it("is null until a join reply says the server takes parts", () => {
	expect(attachmentPartSize()).toBeNull();
	captureServerFeatures({
		features: { chunked_attachment_upload: true, attachment_part_size: 8_388_608 },
	});
	expect(attachmentPartSize()).toBe(8_388_608);
});

it("is null when chunked is off, and ignores malformed replies", () => {
	captureServerFeatures({ features: { chunked_attachment_upload: false } });
	expect(attachmentPartSize()).toBeNull();
	captureServerFeatures({
		features: { chunked_attachment_upload: true, attachment_part_size: "x" },
	});
	expect(attachmentPartSize()).toBeNull();
	captureServerFeatures(undefined);
	expect(attachmentPartSize()).toBeNull();
});

describe("isBlockedFileName", () => {
	test("allows everything until the server sends its list", () => {
		expect(isBlockedFileName("a.exe")).toBe(false);
	});

	test("matches the last extension the way the server does", () => {
		captureServerFeatures({ features: { blocked_extensions: [".exe", ".appimage"] } });
		expect(isBlockedFileName("Tool.AppImage")).toBe(true);
		expect(isBlockedFileName("evil.exe.")).toBe(true);
		expect(isBlockedFileName("evil.exe  ")).toBe(true);
		expect(isBlockedFileName("notes.txt.exe")).toBe(true);
		expect(isBlockedFileName("setup.exe.zip")).toBe(false);
		expect(isBlockedFileName(".exe")).toBe(false);
		expect(isBlockedFileName("photo.png")).toBe(false);
	});

	test("an older server without the list keeps the previous one", () => {
		captureServerFeatures({ features: { blocked_extensions: [".exe"] } });
		captureServerFeatures({ features: { raw_attachment_upload: true } });
		expect(isBlockedFileName("a.exe")).toBe(true);
	});
});
