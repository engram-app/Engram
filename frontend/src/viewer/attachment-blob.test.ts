import { beforeEach, expect, test, vi } from "vitest";
import { api } from "../api/client";
import { loadAttachmentUrl, resolveAttachmentTarget } from "./attachment-blob";

beforeEach(() => {
	URL.createObjectURL = vi.fn(() => "blob:x");
});

test("resolves an exact path, then a bare file name, else null", () => {
	const list = [{ path: "img/a.png" }, { path: "b.png" }];
	expect(resolveAttachmentTarget(list, "img/a.png")).toBe("img/a.png");
	expect(resolveAttachmentTarget(list, "a.png")).toBe("img/a.png");
	expect(resolveAttachmentTarget(list, "nope.png")).toBeNull();
});

test("fetches each path once and encodes the segments", async () => {
	const get = vi.spyOn(api, "getBlob").mockResolvedValue(new Blob(["x"]));
	await loadAttachmentUrl("my dir/p ic.png");
	await loadAttachmentUrl("my dir/p ic.png");
	expect(get).toHaveBeenCalledTimes(1);
	expect(get).toHaveBeenCalledWith("/attachments/my%20dir/p%20ic.png?raw=1");
});

test("uniqueAttachmentName suffixes a taken name, keeping the extension", async () => {
	const { uniqueAttachmentName } = await import("./attachment-blob");
	const list = [{ path: "pic.png" }, { path: "pic 1.png" }, { path: "x/other.png" }];
	expect(uniqueAttachmentName(list, "fresh.png")).toBe("fresh.png");
	expect(uniqueAttachmentName(list, "pic.png")).toBe("pic 2.png");
	expect(uniqueAttachmentName(list, "noext")).toBe("noext");
});

test("the image cache is per vault, and clearAttachmentUrls drops it (user change)", async () => {
	const { clearAttachmentUrls } = await import("./attachment-blob");
	const { setActiveVaultId } = await import("../api/active-vault");
	clearAttachmentUrls(); // earlier tests in this file left entries behind
	await new Promise((r) => setTimeout(r, 0)); // let their async revokes land before we count
	const get = vi
		.spyOn(api, "getBlob")
		.mockClear()
		.mockResolvedValue(new Blob(["x"]));
	const revoke = vi.fn();
	URL.revokeObjectURL = revoke;
	setActiveVaultId("vault-a");
	await loadAttachmentUrl("same/path.png");
	setActiveVaultId("vault-b");
	await loadAttachmentUrl("same/path.png");
	expect(get).toHaveBeenCalledTimes(2); // same path, different vault: not a cache hit
	clearAttachmentUrls();
	await Promise.resolve();
	await Promise.resolve();
	expect(revoke).toHaveBeenCalledTimes(2);
	await loadAttachmentUrl("same/path.png");
	expect(get).toHaveBeenCalledTimes(3); // cleared: refetched
});
