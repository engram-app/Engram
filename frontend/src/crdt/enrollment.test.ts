import { describe, expect, it, vi } from "vitest";
import { CrdtEnrollment } from "./enrollment";

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
});
