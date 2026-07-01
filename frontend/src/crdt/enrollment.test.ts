import { describe, it, expect, vi } from "vitest";
import { CrdtEnrollment } from "./enrollment";

describe("CrdtEnrollment", () => {
	it("enrolls a .md path once, idempotently", () => {
		const startSync = vi.fn().mockResolvedValue(undefined);
		const e = new CrdtEnrollment({ startSync, resetSync: () => {} });
		e.enroll("a.md");
		e.enroll("a.md");
		expect(startSync).toHaveBeenCalledTimes(1);
	});

	it("ignores non-.md paths", () => {
		const startSync = vi.fn().mockResolvedValue(undefined);
		const e = new CrdtEnrollment({ startSync, resetSync: () => {} });
		e.enroll("a.canvas");
		e.enroll("img.png");
		expect(startSync).not.toHaveBeenCalled();
	});

	it("reset re-arms enroll and calls resetSync", () => {
		const startSync = vi.fn().mockResolvedValue(undefined);
		const resetSync = vi.fn();
		const e = new CrdtEnrollment({ startSync, resetSync });
		e.enroll("a.md");
		e.reset("a.md");
		e.enroll("a.md");
		expect(startSync).toHaveBeenCalledTimes(2);
		expect(resetSync).toHaveBeenCalledWith("a.md");
	});
});
