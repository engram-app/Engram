import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { SubscriptionStatusData } from "@/lib/paddle-types";
import { SubscriptionStatusCard } from "./subscription-status-card";

function subscription(status: string): SubscriptionStatusData {
	return {
		items: [{ productName: "Starter", quantity: 1, lineTotal: 7 }],
		totalAmount: 7,
		currency: "USD",
		interval: "month",
		status: status as SubscriptionStatusData["status"],
		startedAt: "2026-10-01T00:00:00Z",
	};
}

describe("SubscriptionStatusCard status badge", () => {
	it("shows a translated generic label, never the raw wire value, for an unknown status", () => {
		render(<SubscriptionStatusCard subscription={subscription("on_hold")} />);
		expect(screen.getByText("Unknown")).toBeTruthy();
		expect(screen.queryByText(/on.hold/iu)).toBeNull();
	});
});
