import { beforeEach, expect, it } from "vitest";
import { attachmentPartSize, captureServerFeatures, resetServerFeatures } from "./server-features";

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
