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

	it("shows no plan badge beside the avatar on any plan", () => {
		for (const tier of ["free", "starter", "pro"] as const) {
			billing.data = { tier };
			const { unmount } = renderUserMenu();
			// The avatar trigger is the only control: no pill, label or extra button.
			expect(screen.getAllByRole("button")).toEqual([
				screen.getByRole("button", { name: "User menu" }),
			]);
			expect(screen.queryByText(/^(?:Free|Starter|Pro)$/u)).toBeNull();
			unmount();
		}
	});

	it("names Free under the email and offers Upgrade, which opens billing as a user_menu click", () => {
		billing.data = { tier: "free" };
		renderUserMenu();
		openMenu();
		expect(screen.getByText("Free plan")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("menuitem", { name: "Upgrade" }));
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", { source: "user_menu" });
		expect(screen.getByTestId("hash")).toHaveTextContent("billing");
	});

	it("still offers Upgrade on Starter, which is below Pro", () => {
		billing.data = { tier: "starter" };
		renderUserMenu();
		openMenu();
		expect(screen.getByText("Starter plan")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("menuitem", { name: "Upgrade" }));
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", { source: "user_menu" });
		expect(screen.getByTestId("hash")).toHaveTextContent("billing");
	});

	it("names Pro and does not nudge", () => {
		billing.data = { tier: "pro" };
		renderUserMenu();
		openMenu();
		expect(screen.getByText("Pro plan")).toBeInTheDocument();
		expect(screen.queryByRole("menuitem", { name: "Upgrade" })).toBeNull();
	});

	it("shows no plan on self-host, where the backend still reports free", () => {
		config.billingEnabled = false;
		billing.data = { tier: "free" };
		renderUserMenu();
		openMenu();
		expect(screen.queryByText("Free plan")).toBeNull();
		expect(screen.queryByRole("menuitem", { name: "Upgrade" })).toBeNull();
	});

	it("shows no plan, rather than crashing, for a tier this build does not know", () => {
		billing.data = { tier: "enterprise" } as unknown as { tier: "pro" };
		renderUserMenu();
		openMenu();
		expect(screen.queryByText(/ plan$/u)).toBeNull();
		expect(screen.queryByRole("menuitem", { name: "Upgrade" })).toBeNull();
	});

	it("shows no plan before billing status loads", () => {
		renderUserMenu();
		openMenu();
		expect(screen.queryByText(/ plan$/u)).toBeNull();
		expect(screen.queryByRole("menuitem", { name: "Upgrade" })).toBeNull();
	});
});
