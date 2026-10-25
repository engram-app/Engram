import { rlog } from "../observability/remote-log";

export class CrdtEnrollment {
	private readonly enrolled = new Set<string>();
	private readonly startSync: (noteId: string) => Promise<void>;
	private readonly resetSync: (noteId: string) => void;

	constructor(opts: {
		startSync: (noteId: string) => Promise<void>;
		resetSync: (noteId: string) => void;
	}) {
		this.startSync = opts.startSync;
		this.resetSync = opts.resetSync;
	}

	// CRDT manages MARKDOWN only — mirrors the server-side `.md` gate. Enforced
	// by the caller now: a note_id carries no extension to check here, so
	// session.ts's openDoc (client-initiated) and the server's crdt_doc_ready
	// emission (server-echo, already .md-gated in crdt_deliver.ex) are the two
	// gates that keep enroll() from ever seeing a non-markdown note.
	enroll(noteId: string): void {
		if (this.enrolled.has(noteId)) {
			return;
		}
		this.enrolled.add(noteId);
		// A rejection would otherwise be unhandled. Note id only, no content.
		this.startSync(noteId).catch((err: unknown) => {
			rlog().warn(
				"crdt",
				`enroll startSync failed note=${noteId} error=${err instanceof Error ? err.name : "unknown"}`,
			);
		});
	}

	reset(noteId: string): void {
		this.enrolled.delete(noteId);
		this.resetSync(noteId);
	}

	resetAll(): void {
		for (const noteId of this.enrolled) {
			this.resetSync(noteId);
		}
		this.enrolled.clear();
	}
}
