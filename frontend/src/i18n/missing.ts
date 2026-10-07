import type { Entry } from "./keys-scan";
import type { Catalog } from "./translate";

interface Report {
	total: number;
	missing: Record<string, Entry[]>;
}

function findMissing(entries: readonly Entry[], catalogs: Record<string, Catalog>): Report {
	return {
		total: entries.length,
		missing: Object.fromEntries(
			Object.entries(catalogs).map(([locale, catalog]) => [
				locale,
				entries.filter((e) => !(e.key in catalog)),
			]),
		),
	};
}

export { findMissing };
