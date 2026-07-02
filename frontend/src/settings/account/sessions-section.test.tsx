import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SessionsSection } from "./sessions-section";

const current = {
	id: "sess_current",
	latestActivity: { deviceType: "Mac", browserName: "Chrome" },
	revoke: vi.fn(),
};
const other = {
	id: "sess_other",
	latestActivity: { deviceType: "iPhone", browserName: "Safari" },
	revoke: vi.fn().mockResolvedValue({}),
};

vi.mock("@clerk/react", () => ({
	useSessionList: () => ({ isLoaded: true, sessions: [current, other] }),
	useSession: () => ({ session: { id: "sess_current" } }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

describe("SessionsSection", () => {
	beforeEach(() => vi.clearAllMocks());

	it("marks the current session and hides its revoke button", () => {
		render(<SessionsSection />);
		expect(screen.getByText(/current/iu)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: /revoke sess_current/iu })).not.toBeInTheDocument();
	});

	it("revokes another session", async () => {
		render(<SessionsSection />);
		fireEvent.click(screen.getByRole("button", { name: /revoke .*iphone/iu }));
		await waitFor(() => expect(other.revoke).toHaveBeenCalled());
	});
});
