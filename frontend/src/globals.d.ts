declare global {
	interface Window {
		/**
		 * Phoenix SSR-injects the runtime config here on the selfhost path, so the
		 * app resolves it on the first microtask instead of fetching /config.json.
		 */
		__ENGRAM_CONFIG__?: Record<string, unknown>;
		/** CRDT phase timings, read over CDP without a UI. See src/crdt/perf.ts. */
		__engramCrdtPerf?: () => unknown;
		__engramCrdtPerfReset?: () => void;
	}
}

export {};
