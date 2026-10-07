import { describe, expect, it } from "vitest";
import { findMatchingVault } from "./match-vault";

const v = (id: string, name: string) => ({ id, name });

describe("findMatchingVault", () => {
	it("matches an exact name", () => {
		expect(findMatchingVault([v("1", "Health"), v("2", "Work")], "Work")?.id).toBe("2");
	});

	it("ignores case and surrounding space when only one vault fits", () => {
		expect(findMatchingVault([v("1", "Health")], "  health ")?.id).toBe("1");
	});

	it("prefers the exact-case vault among case-insensitive matches", () => {
		expect(findMatchingVault([v("1", "health"), v("2", "Health")], "Health")?.id).toBe("2");
	});

	it("suggests nothing when several vaults fit and none is exact", () => {
		expect(findMatchingVault([v("1", "health"), v("2", "HEALTH")], "Health")).toBeUndefined();
	});

	it("suggests nothing for a blank or unknown name", () => {
		expect(findMatchingVault([v("1", "Health")], "")).toBeUndefined();
		expect(findMatchingVault([v("1", "Health")], "Brain Dump")).toBeUndefined();
	});
});
