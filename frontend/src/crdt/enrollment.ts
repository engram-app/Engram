export class CrdtEnrollment {
	private readonly enrolled = new Set<string>();
	private readonly startSync: (noteId: string) => Promise<void>;
	private readonly resetSync: (noteId: string) => void;
	private readonly onAfterEnroll?: (noteId: string) => Promise<void>;

	constructor(opts: {
		startSync: (noteId: string) => Promise<void>;
		resetSync: (noteId: string) => void;
		onAfterEnroll?: (noteId: string) => Promise<void>;
	}) {
		this.startSync = opts.startSync;
		this.resetSync = opts.resetSync;
		this.onAfterEnroll = opts.onAfterEnroll;
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
		this.startSync(noteId).then(() => this.onAfterEnroll?.(noteId));
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
