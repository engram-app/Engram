import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { ThemeProvider } from "../theme/theme-provider";
import UserMenu from "./user-menu";

vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ user: { email: "todd@example.com" }, logout: vi.fn() }),
}));

const config = vi.hoisted(() => ({ billingEnabled: true }));
vi.mock("../config-context", () => ({ useConfig: () => config }));

const billing = vi.hoisted(() => ({
	data: undefined as { tier: "free" | "starter" | "pro" } | undefined,
}));
vi.mock("../api/queries", () => ({ useBillingStatus: () => ({ data: billing.data }) }));

vi.mock("../analytics/track", () => ({ track: vi.fn() }));

vi.mock("../feedback/feedback-dialog", () => ({
	FeedbackDialog: ({ open }: { open: boolean }) => (open ? <p>feedback dialog open</p> : null),
}));

function LocationProbe() {
	const { hash } = useLocation();
	return <p data-testid="hash">{hash}</p>;
}

function renderUserMenu() {
	return render(
		<ThemeProvider>
			<MemoryRouter>
				<UserMenu />
				<LocationProbe />
			</MemoryRouter>
		</ThemeProvider>,
	);
}

// Radix DropdownMenu opens on keyDown Enter/Space against its trigger; happy-dom
// doesn't fully model pointer events, so we drive the menu via keyboard.
function openMenu() {
	fireEvent.keyDown(screen.getByRole("button", { name: /user menu/iu }), { key: "Enter" });
}

describe("UserMenu", () => {
	it("renders an avatar trigger from the user email initial", () => {
		renderUserMenu();
		const trigger = screen.getByRole("button", { name: "User menu" });
		expect(trigger).toBeInTheDocument();
		expect(trigger).toHaveTextContent("T");
	});
});

describe("UserMenu — theme row", () => {
	it("opens the menu and exposes Light / Dark / System rows", () => {
		renderUserMenu();
		openMenu();
		expect(screen.getByRole("menuitemradio", { name: "Light" })).toBeInTheDocument();
		expect(screen.getByRole("menuitemradio", { name: "Dark" })).toBeInTheDocument();
		expect(screen.getByRole("menuitemradio", { name: "System" })).toBeInTheDocument();
	});

	it("selecting a theme updates aria-checked on that row", () => {
		renderUserMenu();
		openMenu();
		fireEvent.click(screen.getByRole("menuitemradio", { name: "Dark" }));
		openMenu();
		expect(screen.getByRole("menuitemradio", { name: "Dark" })).toHaveAttribute(
			"aria-checked",
			"true",
		);
	});
});

describe("UserMenu — feedback", () => {
	it("hides Send feedback on self-host, where nobody receives it", () => {
		config.billingEnabled = false;
		renderUserMenu();
		openMenu();
		expect(screen.queryByRole("menuitem", { name: /send feedback/iu })).toBeNull();
		config.billingEnabled = true;
	});

	it("opens the feedback dialog from the menu", () => {
		renderUserMenu();
		openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: /send feedback/iu }));
		expect(screen.getByText("feedback dialog open")).toBeInTheDocument();
	});
});

describe("UserMenu — plan", () => {
	afterEach(() => {
		billing.data = undefined;
		config.billingEnabled = true;
		vi.mocked(track).mockClear();
	});

	it("badges a Free user and offers Upgrade, which opens billing as a user_menu click", () => {
		billing.data = { tier: "free" };
		renderUserMenu();
		expect(screen.getByTestId("plan-badge")).toHaveTextContent("Free");
		openMenu();
		expect(screen.getByText("Free plan")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("menuitem", { name: "Upgrade" }));
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", { source: "user_menu" });
		expect(screen.getByTestId("hash")).toHaveTextContent("billing");
	});

	it("makes the Free badge a button that opens billing as a plan_badge click", () => {
		billing.data = { tier: "free" };
		renderUserMenu();
		const badge = screen.getByRole("button", { name: "Free plan: See paid plans" });
		expect(badge).toHaveTextContent("Free");
		fireEvent.click(badge);
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", { source: "plan_badge" });
		expect(screen.getByTestId("hash")).toHaveTextContent("billing");
		// The badge is not the avatar trigger: clicking it opens billing, not the menu.
		expect(screen.queryByRole("menu")).toBeNull();
		expect(screen.getByRole("button", { name: "User menu" })).not.toContainElement(badge);
	});

	it("puts the pill before the avatar when it sits beside it, so focus order matches", () => {
		billing.data = { tier: "free" };
		render(
			<ThemeProvider>
				<MemoryRouter>
					<UserMenu planPlacement="beside" />
				</MemoryRouter>
			</ThemeProvider>,
		);
		const [first, second] = screen.getAllByRole("button");
		expect(first).toHaveAccessibleName("Free plan: See paid plans");
		expect(second).toHaveAccessibleName("User menu");
	});

	it("still offers Upgrade on Starter, which is below Pro, but keeps its label static", () => {
		billing.data = { tier: "starter" };
		renderUserMenu();
		expect(screen.getByTestId("plan-badge")).toHaveTextContent("Starter");
		expect(screen.queryByRole("button", { name: /see paid plans/iu })).toBeNull();
		openMenu();
		expect(screen.getByText("Starter plan")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("menuitem", { name: "Upgrade" }));
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", { source: "user_menu" });
		expect(screen.getByTestId("hash")).toHaveTextContent("billing");
	});

	it("names a paid plan and does not nudge", () => {
		billing.data = { tier: "pro" };
		renderUserMenu();
		expect(screen.getByTestId("plan-badge")).toHaveTextContent("Pro");
		expect(screen.queryByRole("button", { name: /see paid plans/iu })).toBeNull();
		openMenu();
		expect(screen.getByText("Pro plan")).toBeInTheDocument();
		expect(screen.queryByRole("menuitem", { name: "Upgrade" })).toBeNull();
	});

	it("shows no plan on self-host, where the backend still reports free", () => {
		config.billingEnabled = false;
		billing.data = { tier: "free" };
		renderUserMenu();
		expect(screen.queryByTestId("plan-badge")).toBeNull();
		openMenu();
		expect(screen.queryByText("Free plan")).toBeNull();
		expect(screen.queryByRole("menuitem", { name: "Upgrade" })).toBeNull();
	});

	it("shows no plan, rather than crashing, for a tier this build does not know", () => {
		billing.data = { tier: "enterprise" } as unknown as { tier: "pro" };
		renderUserMenu();
		expect(screen.getByRole("button", { name: "User menu" })).toBeInTheDocument();
		expect(screen.queryByTestId("plan-badge")).toBeNull();
	});

	it("shows no plan before billing status loads", () => {
		renderUserMenu();
		expect(screen.queryByTestId("plan-badge")).toBeNull();
	});
});
