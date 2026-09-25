import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { BillingStatus } from "../api/queries";
import CurrentPlanCard from "./current-plan-card";

function status(overrides: Partial<BillingStatus> = {}): BillingStatus {
	return {
		tier: "starter",
		active: true,
		trial_days_remaining: 0,
		subscription: { status: "active", tier: "starter", current_period_end: "2026-07-01T12:00:00Z" },
		caps: {
			obsidian_connections: null,
			mcp_connections: null,
			api_write_enabled: true,
			vaults: null,
		},
		current_connections: { obsidian: 0, mcp: 0 },
		device_swap_cooldown_remaining_hours: null,
		...overrides,
	};
}

describe("CurrentPlanCard", () => {
	it("tells a capped user how many of their newest notes are not searchable", () => {
		render(
			<CurrentPlanCard
				billing={status({ tier: "free", subscription: null })}
				indexStatus={{ indexed: 2000, total: 3312 }}
			/>,
		);
		expect(
			screen.getByText(
				"1,312 of your notes aren't searchable on Free. Only your oldest 2,000 are indexed, so your newest notes won't show up in search.",
			),
		).toBeInTheDocument();
	});

	it("says nothing about search coverage when every note is indexed", () => {
		render(<CurrentPlanCard billing={status()} indexStatus={{ indexed: 0, total: 0 }} />);
		expect(screen.queryByText(/searchable/iu)).not.toBeInTheDocument();
	});

	it("shows the tier label and active status", () => {
		render(<CurrentPlanCard billing={status()} />);
		expect(screen.getByText("Starter")).toBeInTheDocument();
		expect(screen.getByText(/active/iu)).toBeInTheDocument();
	});

	it("labels the period-end date as a renewal when the subscription is active", () => {
		render(<CurrentPlanCard billing={status()} />);
		expect(screen.getByText(/renews on/iu)).toBeInTheDocument();
		expect(screen.getByText(/2026/u)).toBeInTheDocument();
	});

	it("labels the period-end date as access-ending when canceled", () => {
		render(
			<CurrentPlanCard
				billing={status({
					active: false,
					subscription: {
						status: "canceled",
						tier: "pro",
						current_period_end: "2026-07-01T12:00:00Z",
					},
				})}
			/>,
		);
		expect(screen.getByText(/access ends on/iu)).toBeInTheDocument();
		expect(screen.queryByText(/renews on/iu)).not.toBeInTheDocument();
	});

	it("surfaces remaining trial days while trialing", () => {
		render(
			<CurrentPlanCard
				billing={status({
					tier: "trial",
					trial_days_remaining: 5,
					subscription: {
						status: "trialing",
						tier: "starter",
						current_period_end: "2026-07-01T12:00:00Z",
					},
				})}
			/>,
		);
		expect(screen.getByText(/5 days/iu)).toBeInTheDocument();
	});
});
