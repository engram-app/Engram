import { beforeEach, expect, test, vi } from "vitest";
import { ApiError, LimitExceededError } from "@/api/client";
import { captureServerFeatures, resetServerFeatures } from "@/api/server-features";
import { englishT } from "@/i18n/translate";
import { uploadFilesTo, withoutBlocked } from "./upload-files";

const toastError = vi.fn();
vi.mock("sonner", () => ({ toast: { error: (m: string) => toastError(m) } }));

const f = (name: string) => new File(["x"], name, { type: "image/png" });
beforeEach(() => toastError.mockReset());

test("uploads into the folder and returns the vault paths", async () => {
	const upload = vi.fn().mockResolvedValue({});
	const done = await uploadFilesTo({
		upload,
		existing: [],
		files: [f("a.png")],
		folder: "Docs",
		t: englishT,
	});
	expect(upload).toHaveBeenCalledWith(expect.objectContaining({ path: "Docs/a.png" }));
	expect(done).toEqual(["Docs/a.png"]);
});

test("does not clobber a file already in that folder, but ignores other folders", async () => {
	const upload = vi.fn().mockResolvedValue({});
	const existing = [{ path: "Docs/a.png" }, { path: "Other/b.png" }];
	await uploadFilesTo({
		upload,
		existing,
		files: [f("a.png"), f("b.png")],
		folder: "Docs",
		t: englishT,
	});
	expect(upload.mock.calls.map((c) => c[0].path)).toEqual(["Docs/a 1.png", "Docs/b.png"]);
});

test("uploads two same-named files in one drop under different names", async () => {
	const upload = vi.fn().mockResolvedValue({});
	await uploadFilesTo({
		upload,
		existing: [],
		files: [f("a.png"), f("a.png")],
		folder: "",
		t: englishT,
	});
	expect(upload.mock.calls.map((c) => c[0].path)).toEqual(["a.png", "a 1.png"]);
});

test("one failure toasts and the rest still upload; a plan limit does not toast", async () => {
	const upload = vi
		.fn()
		.mockRejectedValueOnce(new Error("boom"))
		.mockRejectedValueOnce(new LimitExceededError("attachments_disabled", null, null, null, null))
		.mockResolvedValueOnce({});
	const done = await uploadFilesTo({
		upload,
		existing: [],
		files: [f("a.png"), f("b.png"), f("c.png")],
		folder: "",
		t: englishT,
	});
	expect(done).toEqual(["c.png"]);
	expect(toastError).toHaveBeenCalledTimes(1);
	expect(toastError).toHaveBeenCalledWith("a.png: Upload failed. Try again.");
});

test("a dropped executable toasts that executables don't sync", async () => {
	const upload = vi.fn().mockRejectedValue(new ApiError(415, "extension_not_allowed"));
	await uploadFilesTo({ upload, existing: [], files: [f("a.exe")], folder: "", t: englishT });
	expect(toastError).toHaveBeenCalledWith("a.exe: Executable files don't sync.");
});

test("a network failure toasts Upload failed. Try again.", async () => {
	const upload = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));
	await uploadFilesTo({ upload, existing: [], files: [f("a.png")], folder: "", t: englishT });
	expect(toastError).toHaveBeenCalledWith("a.png: Upload failed. Try again.");
});

test("a second drop of the same name inside the refetch window does not overwrite the first", async () => {
	const upload = vi.fn().mockResolvedValue({});
	// `existing` is stale in both calls: the refetch has not landed yet.
	await uploadFilesTo({ upload, existing: [], files: [f("race.png")], folder: "", t: englishT });
	await uploadFilesTo({ upload, existing: [], files: [f("race.png")], folder: "", t: englishT });
	expect(upload.mock.calls.map((c) => c[0].path)).toEqual(["race.png", "race 1.png"]);
});

test("characters that break a [[wikilink]] target are replaced in the uploaded name", async () => {
	const upload = vi.fn().mockResolvedValue({});
	await uploadFilesTo({
		upload,
		existing: [],
		files: [f("shot #2 [a]|b^c.png")],
		folder: "",
		t: englishT,
	});
	expect(upload.mock.calls[0]?.[0].path).toBe("shot -2 -a--b-c.png");
});

test("withoutBlocked drops executables with one toast each and keeps the rest", () => {
	captureServerFeatures({ features: { blocked_extensions: [".appimage"] } });
	const kept = withoutBlocked([f("a.png"), f("Tool.AppImage")], englishT);
	expect(kept.map((x) => x.name)).toEqual(["a.png"]);
	expect(toastError).toHaveBeenCalledWith("Tool.AppImage: Executable files don't sync.");
	resetServerFeatures();
});
