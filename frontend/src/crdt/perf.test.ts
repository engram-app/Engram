import { beforeEach, describe, expect, it } from "vitest";
import { crdtMark, report, reset } from "./perf";

describe("crdt open-path timing", () => {
	beforeEach(() => {
		localStorage.setItem("engramCrdtPerf", "1");
		reset();
	});

	it("reports each phase as a delta from that open's start", () => {
		crdtMark("n1", "open:start");
		crdtMark("n1", "open:session-ready");
		crdtMark("n1", "open:resolved");

		const rows = report();
		expect(rows).toHaveLength(1);
		const [row] = rows;
		if (!row) {
			throw new Error("unreachable: length asserted above");
		}
		expect(row.noteId).toBe("n1");
		// Real clock, so assert ordering and presence rather than exact ms.
		expect(row["open:session-ready"]).toBeGreaterThanOrEqual(0);
		expect(row["open:resolved"]).toBeGreaterThanOrEqual(row["open:session-ready"] ?? 0);
		expect(row.total).toBe(row["open:resolved"]);
	});

	// The reason rows are cut on `open:start` and not grouped by note id: a
	// note reopened later must not have its phases folded into the first
	// open's row, which would silently report one bogus blended timing.
	it("splits a reopened note into separate rows", () => {
		crdtMark("n1", "open:start");
		crdtMark("n1", "entry:cold");
		crdtMark("n1", "open:start");
		crdtMark("n1", "entry:warm");

		const rows = report();
		expect(rows).toHaveLength(2);
		expect(rows[0]).toHaveProperty("entry:cold");
		expect(rows[0]).not.toHaveProperty("entry:warm");
		expect(rows[1]).toHaveProperty("entry:warm");
		expect(rows[1]).not.toHaveProperty("entry:cold");
	});

	// Marks that arrive with no open:start to anchor them (instrumentation
	// switched on mid-open) are dropped, not attributed to some other open.
	it("drops phases with no preceding open:start", () => {
		crdtMark("orphan", "step1:reply");
		expect(report()).toHaveLength(0);
	});

	it("keeps concurrent opens of different notes apart", () => {
		crdtMark("a", "open:start");
		crdtMark("b", "open:start");
		crdtMark("b", "idb:synced");
		crdtMark("a", "step1:sent");

		const rows = report();
		expect(rows.map((r) => r.noteId)).toEqual(["a", "b"]);
		expect(rows[0]).toHaveProperty("step1:sent");
		expect(rows[0]).not.toHaveProperty("idb:synced");
		expect(rows[1]).toHaveProperty("idb:synced");
	});
});
