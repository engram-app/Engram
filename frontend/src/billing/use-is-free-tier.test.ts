import { renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

let billingEnabled = true;
let tier: string | undefined = "free";

vi.mock("../config-context", async () => {
	const actual = await vi.importActual<typeof import("../config-context")>("../config-context");
	return {
		...actual,
		useConfig: () => ({ billingEnabled }) as ReturnType<typeof actual.useConfig>,
	};
});

vi.mock("../api/queries", async () => {
	const actual = await vi.importActual<typeof import("../api/queries")>("../api/queries");
	return { ...actual, useBillingStatus: () => ({ data: tier ? { tier } : undefined }) };
});

import { useIsFreeTier } from "./use-is-free-tier";

beforeEach(() => {
	billingEnabled = true;
	tier = "free";
});

describe("useIsFreeTier", () => {
	it("true on SaaS free tier", () => {
		billingEnabled = true;
		tier = "free";
		expect(renderHook(() => useIsFreeTier()).result.current).toBe(true);
	});

	it('treats "none" (no subscription) as free on SaaS', () => {
		billingEnabled = true;
		tier = "none";
		expect(renderHook(() => useIsFreeTier()).result.current).toBe(true);
	});

	it("false on paid tiers", () => {
		billingEnabled = true;
		tier = "pro";
		expect(renderHook(() => useIsFreeTier()).result.current).toBe(false);
	});

	it('false on self-host even though tier reports "free"', () => {
		billingEnabled = false;
		tier = "free";
		expect(renderHook(() => useIsFreeTier()).result.current).toBe(false);
	});

	it("false while billing status is still loading", () => {
		billingEnabled = true;
		tier = undefined;
		expect(renderHook(() => useIsFreeTier()).result.current).toBe(false);
	});
});
