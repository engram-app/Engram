import { describe, expect, it } from "vitest";
import { fileToBase64 } from "./file-to-base64";

describe("fileToBase64", () => {
	it("returns base64 WITHOUT the data: prefix", async () => {
		// "hi" → base64 "aGk="
		const file = new File([new Uint8Array([0x68, 0x69])], "hi.txt", { type: "text/plain" });
		const out = await fileToBase64(file);
		expect(out).toBe("aGk=");
	});

	it("handles empty files", async () => {
		const file = new File([], "empty.bin", { type: "application/octet-stream" });
		const out = await fileToBase64(file);
		expect(out).toBe("");
	});
});
