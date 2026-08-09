/** Opt-in timing for the note-open path (#1317).
 *
 * A cached note still takes ~550ms to show content, and the cost is spread
 * across four things nobody has measured against each other: the session
 * wait, the per-note IndexedDB open, the STEP1 handshake round-trip, and
 * CodeMirror construction. Every fix proposed in #1317 is sized differently
 * depending on that split, so measure before designing.
 *
 * Off unless `localStorage.engramCrdtPerf === "1"`, so this costs a single
 * boolean read per mark in normal use. Read the results with
 * `window.__engramCrdtPerf()` — see `report()` below.
 */

const STORAGE_KEY = "engramCrdtPerf";
/** Bounded so a long session can't grow this without limit. Ample for the
 *  handful of opens a measurement run performs. */
const MAX_SAMPLES = 2000;

type Phase =
	| "open:start"
	| "open:session-ready"
	// NOTE when reading a report: `entry:warm` also fires from
	// ChannelBridge.handleFrame's getDoc, so on an open that went through
	// `entry:cold` you will see a LATER `entry:warm` stamped at the moment the
	// first sync frame arrived. That is the frame handler, not the open path —
	// do not read it as the open taking that long. It is also why `total` can
	// exceed the real time-to-content.
	| "entry:warm"
	| "entry:cold"
	| "idb:synced"
	| "open:resolved"
	| "step1:sent"
	| "step1:reply"
	| "editor:construct-start"
	| "editor:construct-end"
	// Emitted when the view is built over an EMPTY Y.Text: the local
	// IndexedDB copy had nothing, so the user stares at a blank editor until
	// step1:reply lands. Its presence is what separates "content was local"
	// from "content came over the wire" — the two have wildly different
	// times-to-content and want completely different fixes.
	| "editor:seeded-empty";

interface Sample {
	t: number;
	noteId: string;
	phase: Phase;
}

interface OpenBase {
	noteId: string;
	/** Span of this open's DISTINCT phases. Deliberately not "latest activity":
	 *  marks keep arriving for a note long after its open finished, and letting
	 *  them extend `total` made it unbounded. Late traffic shows up in
	 *  `repeats` instead. */
	total: number;
	/** ms until the same note opened again, on a row that recorded NO phases.
	 *
	 *  Do not collapse this into a boolean "artefact" flag. Two very different
	 *  things produce a phase-less row: StrictMode's mount/unmount/mount, which
	 *  re-opens within a millisecond or two, and an open that STALLED (a hung
	 *  session promise is one of the four costs #1317 exists to measure) which
	 *  the user then re-clicked seconds later. Labelling both as noise throws
	 *  away the only recorded evidence of the second. The gap separates them —
	 *  read it, don't assume. */
	reopenedAfterMs?: number;
	/** Phases that fired more than once inside this open, with the LAST delta
	 *  seen.
	 *
	 *  First-wins keeps the phase value honest for the common case, but it
	 *  cannot be right in every case: `crdtMark` carries only a note id, so a
	 *  late mark from an abandoned open is indistinguishable from a real one
	 *  belonging to the current row. Rather than silently pick, record that the
	 *  ambiguity happened — a row whose `step1:reply` repeats at 600ms is
	 *  telling you not to trust its 5ms. Removing the ambiguity outright needs
	 *  an open id threaded through session/manager/channel; `entry()` is
	 *  reached from both the open path and the frame handler, so there is
	 *  nowhere to infer it today. */
	repeats?: Partial<Record<Phase, { count: number; lastMs: number }>>;
}

const samples: Sample[] = [];
let enabled: boolean | null = null;

function on(): boolean {
	if (enabled === null) {
		try {
			enabled = localStorage.getItem(STORAGE_KEY) === "1";
		} catch {
			// Private mode / storage disabled — stay off rather than throw on
			// every mark.
			enabled = false;
		}
	}
	return enabled;
}

// Exposed for reading over CDP without a UI. `report`/`reset` are function
// declarations, so they hoist — wiring them here keeps every export last.
// Guarded so it never throws in a non-browser (test/SSR) context.
if (typeof window !== "undefined") {
	(window as unknown as { __engramCrdtPerf: typeof report }).__engramCrdtPerf = report;
	(window as unknown as { __engramCrdtPerfReset: typeof reset }).__engramCrdtPerfReset = reset;
}

/** One note open: each phase as ms elapsed since that open's `open:start`. */
export type OpenRow = OpenBase & Partial<Record<Phase, number>>;

export type CrdtPhase = Phase;

export function crdtMark(noteId: string, phase: Phase): void {
	if (!on()) {
		return;
	}
	if (samples.length >= MAX_SAMPLES) {
		samples.shift();
	}
	samples.push({ t: performance.now(), noteId, phase });
}

/** One row per note open, phases as deltas in ms from `open:start`.
 *
 * Grouped by `open:start` boundary rather than by note id alone, so
 * reopening the same note yields separate rows instead of one row whose
 * phases came from two different opens.
 *
 * FIRST value wins for a repeated phase. Several marks fire more than once
 * per open and none of them are stamped from a place that could know it:
 * `step1:reply` sits in `ChannelBridge.handleFrame`, which runs for EVERY
 * inbound sync frame; `entry:warm` fires from that same handler's `getDoc`;
 * `editor:construct-end` re-fires on a theme toggle and on StrictMode's
 * second mount. Under last-wins each of those overwrote a genuine open-path
 * timing with the arrival of unrelated later traffic — silently, since a
 * wrong number here looks exactly like a right one. Guarding at the read
 * layer covers every such source at once, including ones added later, which
 * a guard per call site would not. */
export function report(): OpenRow[] {
	const rows: OpenRow[] = [];
	const current = new Map<string, { start: number; row: OpenRow; phases: number }>();

	for (const s of samples) {
		if (s.phase === "open:start") {
			// A row that recorded nothing before the note re-opened: report the
			// GAP, not a verdict. See `reopenedAfterMs`.
			const prev = current.get(s.noteId);
			if (prev && prev.phases === 0) {
				prev.row.reopenedAfterMs = Math.round(s.t - prev.start);
			}
			const row: OpenRow = { noteId: s.noteId, total: 0 };
			rows.push(row);
			current.set(s.noteId, { start: s.t, row, phases: 0 });
			continue;
		}
		const cur = current.get(s.noteId);
		if (!cur) {
			continue; // phase from before instrumentation was switched on
		}
		const delta = Math.round(s.t - cur.start);
		if (cur.row[s.phase] !== undefined) {
			// Keep the first value, but never discard the fact that it repeated
			// — that is the reader's signal the first value may not be theirs.
			const seen = cur.row.repeats?.[s.phase];
			cur.row.repeats = {
				...cur.row.repeats,
				[s.phase]: { count: (seen?.count ?? 1) + 1, lastMs: delta },
			};
			continue;
		}
		cur.row[s.phase] = delta;
		cur.phases += 1;
		cur.row.total = Math.max(cur.row.total, delta);
	}
	return rows;
}

export function reset(): void {
	samples.length = 0;
	// Re-read the flag on the next mark: `on()` caches, so without this a
	// session that flips localStorage stays stuck at whatever it read first.
	enabled = null;
}
