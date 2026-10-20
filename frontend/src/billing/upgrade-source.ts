import type { UpgradeSource } from "../analytics/events";

// Where the user last chose to upgrade from, for `checkout_opened.source`.
// Module state on purpose: the click and the checkout are in one page load,
// and nothing about it should outlive the tab.
let last: UpgradeSource | null = null;

export function noteUpgradeSource(source: UpgradeSource): void {
	last = source;
}

/** The last noted source, or "direct" for a user who opened billing unprompted. */
export function upgradeSource(): UpgradeSource {
	return last ?? "direct";
}
