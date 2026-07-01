import { useContext, useEffect, useState } from "react";
import { getApiBase, joinApiUrl } from "../api/base";
import { ConfigContext } from "../config-context";

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

// Module-level cache so concurrent hook callers share one fetch + result.
// Seeded from config.bootstrap on first hook invocation (the seed is
// stable per page load — config is resolved once during Suspense gate).
let cached: Bootstrap | null | undefined;
let seeded = false;
let inflight: Promise<Bootstrap | null> | null = null;

function fetchBootstrap(): Promise<Bootstrap | null> {
	if (inflight) return inflight;
	inflight = fetch(joinApiUrl(getApiBase(), "/api/auth/bootstrap"))
		.then((r) => (r.ok ? r.json() : null))
		.catch(() => null)
		.then((b: Bootstrap | null) => {
			cached = b;
			return b;
		});
	return inflight;
}

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
		cached = config?.bootstrap;
		seeded = true;
	}

	const [state, setState] = useState<BootstrapState>(cached);

	useEffect(() => {
		if (cached !== undefined) return;
		let cancelled = false;
		fetchBootstrap().then((b) => {
			if (!cancelled) setState(b);
		});
		return () => {
			cancelled = true;
		};
	}, []);

	return state;
}
