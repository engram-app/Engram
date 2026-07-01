export class CrdtEnrollment {
	private readonly enrolled = new Set<string>();
	private readonly startSync: (path: string) => Promise<void>;
	private readonly resetSync: (path: string) => void;
	private readonly onAfterEnroll?: (path: string) => Promise<void>;

	constructor(opts: {
		startSync: (path: string) => Promise<void>;
		resetSync: (path: string) => void;
		onAfterEnroll?: (path: string) => Promise<void>;
	}) {
		this.startSync = opts.startSync;
		this.resetSync = opts.resetSync;
		this.onAfterEnroll = opts.onAfterEnroll;
	}

	enroll(path: string): void {
		// CRDT manages MARKDOWN only — mirrors the server-side `.md` gate.
		if (!path.endsWith(".md")) {
			return;
		}
		if (this.enrolled.has(path)) {
			return;
		}
		this.enrolled.add(path);
		void this.startSync(path).then(() => this.onAfterEnroll?.(path));
	}

	reset(path: string): void {
		this.enrolled.delete(path);
		this.resetSync(path);
	}

	resetAll(): void {
		for (const path of this.enrolled) {
			this.resetSync(path);
		}
		this.enrolled.clear();
	}
}
