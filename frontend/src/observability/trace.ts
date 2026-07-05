// W3C trace-context (traceparent) generation + parsing, plus a coalescing
// beacon buffer that reports client spans to the backend's authed
// `POST /api/telemetry/spans` ingest endpoint. Mirrors the Obsidian
// plugin's `src/observability/traceGen.ts` + `beacon.ts`, repeated here
// because the web SPA lives in a separate repo (backend `frontend/`).
//
// Auth note: the web SPA authenticates with a bearer token, cross-origin in
// saas (app.engram.page -> api.engram.page). `navigator.sendBeacon` cannot
// set an Authorization header, so unlike a same-origin cookie-authed app,
// the transport here is `fetch(..., { keepalive: true })` with an explicit
// Authorization header, resolved the same way `authFetch` resolves it
// (token/apiBase/vaultId), never `navigator.sendBeacon`.
import { getActiveVaultId } from "../api/active-vault";
import { getApiBase, getTracingEnabled } from "../api/base";
import { getAuthToken } from "../api/client";

function hex(bytes: number): string {
	const buf = new Uint8Array(bytes);
	crypto.getRandomValues(buf);
	return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
}

interface BeaconTransport {
	url: string;
	token: string | null;
	vaultId: string | null;
}

const FLUSH_MS = 2000;
const MAX_BATCH = 20;

// Builds the module singleton, wiring the `pagehide` flush as part of
// construction so this stays the only non-export statement in the module
// (all exports are grouped last, per the lint config).
function createBeacon(): BeaconBuffer {
	const buf = new BeaconBuffer(async () => {
		if (!tracingEnabled()) {
			return null;
		}
		return {
			url: getApiBase(),
			token: await getAuthToken(),
			vaultId: getActiveVaultId(),
		};
	});

	// Buffered spans must survive navigation/tab-close. `pagehide` fires
	// reliably on both full navigation and bfcache eviction.
	if (typeof window !== "undefined") {
		window.addEventListener("pagehide", () => {
			buf.flush();
		});
	}

	return buf;
}

export interface TraceContext {
	traceparent: string;
	traceId: string;
	spanId: string;
}

/**
 * A fresh sampled root W3C trace context. Clients own the trace id and the
 * parent pointer (their own span id); the backend generates each beacon
 * span's own id when it materializes the beacon as a child (see the
 * backend's `Engram.Observability.ClientSpan.record/1`).
 */
export function newTraceContext(): TraceContext {
	const traceId = hex(16);
	const spanId = hex(8);
	return { traceparent: `00-${traceId}-${spanId}-01`, traceId, spanId };
}

export interface ParsedTraceparent {
	traceId: string;
	parentSpanId: string;
}

export function parseTraceparent(tp: string): ParsedTraceparent | null {
	const m = /^00-(?<traceId>[0-9a-f]{32})-(?<parentSpanId>[0-9a-f]{16})-[0-9a-f]{2}$/.exec(tp);
	const groups = m?.groups;
	if (!(groups?.traceId && groups.parentSpanId)) {
		return null;
	}
	return { traceId: groups.traceId, parentSpanId: groups.parentSpanId };
}

/**
 * Real config field (`config.ts` `tracingEnabled`, default false), wired at
 * bootstrap time via `setTracingEnabled()` in `api/base.ts` (same
 * module-level-singleton pattern as `apiBase`/`wsBase`: this module is
 * plain TS, not a React component, so it cannot use the `useConfig()`
 * hook). Self-host and OTEL-disabled deployments never flip this true, so
 * every call site below is a single boolean check that does nothing.
 */
export function tracingEnabled(): boolean {
	return getTracingEnabled();
}

export interface BeaconEntry {
	trace_id: string;
	parent_span_id: string;
	name: string;
	start_us: number;
	end_us: number;
	attributes: Record<string, string>;
}

/**
 * Coalescing beacon buffer. `enqueue` is O(1) and never touches the
 * network; spans batch into one `fetch(..., { keepalive: true })` POST on
 * a ~2s timer, at the 20-span cap, or on `pagehide`. All network is
 * fire-and-forget: a beacon failure must never block or fail a note push,
 * a request, or a render. `flush()` never rejects (all failures are caught
 * internally), so callers can invoke it without awaiting or handling it.
 */
export class BeaconBuffer {
	private readonly queue: BeaconEntry[] = [];
	private timer: ReturnType<typeof setTimeout> | null = null;

	// `resolveTransport` returns null when tracing is disabled (or the
	// token/vault aren't ready yet), in which case `flush()` drops the
	// batch without ever touching the network.
	constructor(
		private readonly resolveTransport: () => BeaconTransport | null | Promise<BeaconTransport | null>,
	) {}

	enqueue(entry: BeaconEntry): void {
		this.queue.push(entry);
		if (this.queue.length >= MAX_BATCH) {
			this.flush();
		} else if (!this.timer) {
			this.timer = setTimeout(() => {
				this.flush();
			}, FLUSH_MS);
		}
	}

	async flush(): Promise<void> {
		if (this.timer) {
			clearTimeout(this.timer);
			this.timer = null;
		}
		if (this.queue.length === 0) {
			return;
		}
		const batch = this.queue.splice(0, this.queue.length);
		try {
			const transport = await this.resolveTransport();
			if (!transport) {
				return; // disabled or not ready: drop silently, never network
			}
			const headers: Record<string, string> = { "Content-Type": "application/json" };
			if (transport.token) {
				headers.Authorization = `Bearer ${transport.token}`;
			}
			if (transport.vaultId) {
				headers["X-Vault-ID"] = transport.vaultId;
			}
			await fetch(`${transport.url}/api/telemetry/spans`, {
				method: "POST",
				keepalive: true,
				headers,
				body: JSON.stringify({ spans: batch }),
			});
		} catch {
			// Beacons are best-effort: a network failure must never surface.
		}
	}
}

/**
 * Module singleton shared by `authFetch` (leg A, via header injection) and
 * the live-sync channel handler (leg B render beacon). Resolves
 * token/apiBase/vaultId the same way `authFetch` does; resolves to null
 * (no network, ever) whenever tracing is disabled.
 */
export const beacon = createBeacon();
