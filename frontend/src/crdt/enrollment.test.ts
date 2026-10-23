import { describe, expect, it, vi } from "vitest";
import { CrdtEnrollment } from "./enrollment";

const warn = vi.fn();
vi.mock("../observability/remote-log", () => ({ rlog: () => ({ warn }) }));

describe("CrdtEnrollment", () => {
	it("enrolls a note_id once, idempotently", () => {
		const startSync = vi.fn().mockResolvedValue(undefined);
		const e = new CrdtEnrollment({ startSync, resetSync: () => {} });
		e.enroll("note-1");
		e.enroll("note-1");
		expect(startSync).toHaveBeenCalledTimes(1);
	});

	it("reset re-arms enroll and calls resetSync", () => {
		const startSync = vi.fn().mockResolvedValue(undefined);
		const resetSync = vi.fn();
		const e = new CrdtEnrollment({ startSync, resetSync });
		e.enroll("note-1");
		e.reset("note-1");
		e.enroll("note-1");
		expect(startSync).toHaveBeenCalledTimes(2);
		expect(resetSync).toHaveBeenCalledWith("note-1");
	});

	it("logs a failed startSync by note id, never the error message", async () => {
		const startSync = vi.fn().mockRejectedValue(new Error("note body text"));
		const e = new CrdtEnrollment({ startSync, resetSync: () => {} });
		e.enroll("note-1");
		await vi.waitFor(() => expect(warn).toHaveBeenCalledTimes(1));
		const message = String(warn.mock.calls[0]?.[1]);
		expect(message).toContain("note=note-1");
		expect(message).not.toContain("note body text");
	});
});
