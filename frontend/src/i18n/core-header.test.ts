import { describe, expect, it } from "vitest";
import { coreHeaderOk } from "./core/core";

// The core is vendored into the plugin and marketing repos; its header hash is how
// a copy edited in place (or this canonical copy edited without a sync) is caught.
const files = import.meta.glob<string>("./core/*.ts", {
	query: "?raw",
	import: "default",
	eager: true,
});

describe("i18n core header", () => {
	it.each(Object.entries(files).filter(([p]) => !p.endsWith(".test.ts")))(
		"%s matches its content (run `bun scripts/i18n-core-sync.ts` after editing)",
		(_path, text) => {
			expect(coreHeaderOk(text)).toBe(true);
		},
	);
});
