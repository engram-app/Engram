import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { makeUser } from "./account/section-test-helpers";
import AccountPage from "./account-page";

vi.mock("@clerk/react", () => ({
	useUser: () => ({ user: makeUser(), isLoaded: true }),
	useReverification: (fn: unknown) => fn,
	useSessionList: () => ({ isLoaded: true, sessions: [] }),
	useSession: () => ({ session: { id: "sess_current" } }),
	useClerk: () => ({ signOut: vi.fn().mockResolvedValue({}) }),
}));
vi.mock("@clerk/react/errors", () => ({
	isClerkAPIResponseError: () => false,
	isReverificationCancelledError: () => false,
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock("@/theme/theme-provider", () => ({
	useTheme: () => ({ theme: "system", resolved: "dark", setTheme: vi.fn() }),
}));

// AccountPage now mounts ReportBugSection, whose dialog calls `useReportBug`
// (a useMutation). Rendering bare throws "No QueryClient set", so the page needs
// a provider the way connections-page.test.tsx already does it.
function renderPage() {
	const qc = new QueryClient();
	return render(
		<QueryClientProvider client={qc}>
			<AccountPage />
		</QueryClientProvider>,
	);
}

describe("AccountPage", () => {
	it("renders the section stack with no embedded Clerk UserProfile", () => {
		renderPage();
		expect(screen.getByRole("heading", { name: "Account", level: 1 })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "Profile photo" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "Appearance" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "Password" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /danger zone/iu })).toBeInTheDocument();
	});
});
