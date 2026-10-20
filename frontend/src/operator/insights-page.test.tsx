import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import NotFoundPage from "@/not-found";
import OperatorInsightsPage from "./insights-page";

let mockRole = "operator";
const mockGet = vi.fn();

vi.mock("@/api/queries", () => ({
	useMe: () => ({ isLoading: false, data: { role: mockRole } }),
}));
vi.mock("@/api/client", () => ({ api: { get: (path: string) => mockGet(path) } }));
vi.mock("@/theme/theme-toggle", () => ({ default: () => null }));

function renderAt(url: string) {
	const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={client}>
			<MemoryRouter initialEntries={[url]}>
				<OperatorInsightsPage notFound={<NotFoundPage />} />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("OperatorInsightsPage", () => {
	beforeEach(() => {
		mockRole = "operator";
		mockGet.mockReset();
		mockGet.mockImplementation((path: string) => {
			if (path === "/operator/insights") {
				return Promise.resolve({ reports: ["funnel", "billing"] });
			}
			if (path === "/operator/insights/funnel") {
				return Promise.resolve({
					steps: [
						{ step: "signed_up", users: 4, pct: 100 },
						{ step: "paid", users: 1, pct: 25 },
					],
				});
			}
			if (path === "/operator/insights/users/u1") {
				return Promise.resolve({ user_id: "u1", events: [{ event: "vault_created" }] });
			}
			return Promise.reject(new Error(path));
		});
	});

	it("is the plain 404 page for anyone but an operator, and asks the server nothing", () => {
		mockRole = "member";
		renderAt("/operator");
		expect(screen.getByRole("heading", { name: /page not found/iu })).toBeInTheDocument();
		expect(mockGet).not.toHaveBeenCalled();
	});

	it("lists the reports and shows the first as a table with bars", async () => {
		renderAt("/operator");
		expect(await screen.findByRole("cell", { name: /signed_up/u })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "billing" })).toHaveAttribute(
			"href",
			"/operator?report=billing",
		);
		expect(screen.getAllByRole("meter")).toHaveLength(4);
	});

	it("shows one user's timeline", async () => {
		renderAt("/operator?user=u1");
		expect(await screen.findByText("vault_created")).toBeInTheDocument();
		expect(mockGet).toHaveBeenCalledWith("/operator/insights/users/u1");
	});
});
