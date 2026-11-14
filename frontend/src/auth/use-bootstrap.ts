import { useContext, useEffect, useState } from "react";
import { getApiBase, joinApiUrl } from "../api/base";
import { ConfigContext } from "../config-context";

// Module-level cache so concurrent hook callers share one fetch + result.
// Seeded from config.bootstrap on first hook invocation (the seed is
// stable per page load — config is resolved once during Suspense gate).
let cached: Bootstrap | null | undefined;
let seeded = false;
let inflight: Promise<Bootstrap | null> | null = null;
// Mounted hooks, so a cache update reaches pages that are already on screen.
const listeners = new Set<(b: BootstrapState) => void>();

function fetchBootstrap(): Promise<Bootstrap | null> {
	if (inflight) {
		return inflight;
	}
	inflight = fetch(joinApiUrl(getApiBase(), "/api/auth/bootstrap"))
		.then((r) => (r.ok ? r.json() : null))
		.catch(() => null)
		.then((b: Bootstrap | null) => {
			cached = b;
			return b;
		});
	return inflight;
}

/**
 * Close the claim window in the cache once an account exists. Without this the
 * cached `bootstrap_pending: true` outlives the first signup until a reload:
 * sign-out then bounces /sign-in back to /sign-up, which still shows the
 * first-run setup token field.
 */
export function markBootstrapComplete(): void {
	inflight = null;
	if (cached?.bootstrap_pending) {
		cached = { ...cached, bootstrap_pending: false };
		for (const notify of listeners) {
			notify(cached);
		}
	}
}

export interface Bootstrap {
	bootstrap_pending: boolean;
	registration_mode: "open" | "invite_only" | "closed";
}

// Discriminates "still fetching" from "loaded but no data". A `null` result
// means we definitively know there is no self-host bootstrap (404 / Clerk /
// network error → fall back to defaults). `undefined` means "don't render
// mode-dependent UI yet" — UI shows a skeleton/placeholder until this
// resolves, avoiding the default→correct flash on every navigation.
export type BootstrapState = Bootstrap | null | undefined;

export function useBootstrap(): BootstrapState {
	// Read context directly (not via useConfig()) so test environments that
	// mount LocalSignIn / signup flows without a ConfigProvider don't crash.
	// Bootstrap is a soft hint — a missing config just means "no seed, fetch".
	const config = useContext(ConfigContext);

	// Seed once from the SSR-injected config (selfhost-prod fast path: no
	// fetch on first paint). On CF Pages /config.json typically omits this
	// block — `config.bootstrap` is undefined and we drop through to the
	// public /api/auth/bootstrap endpoint.
	if (!seeded) {
		// biome-ignore lint/nursery/useReactCompiler: module-level seed-once cache, deliberate: the first render reads /config.json synchronously and every later call must see the same value.
		cached = config?.bootstrap;
		// biome-ignore lint/nursery/useReactCompiler: module-level seed-once cache, deliberate: the first render reads /config.json synchronously and every later call must see the same value.
		seeded = true;
	}

	const [state, setState] = useState<BootstrapState>(cached);

	useEffect(() => {
		listeners.add(setState);
		return () => {
			listeners.delete(setState);
		};
	}, []);

	useEffect(() => {
		if (cached !== undefined) {
			return;
		}
		let cancelled = false;
		fetchBootstrap().then((b) => {
			if (!cancelled) {
				setState(b);
			}
		});
		return () => {
			cancelled = true;
		};
	}, []);

	return state;
}
