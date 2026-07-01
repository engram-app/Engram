import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import NotFoundPage from "./not-found";

vi.mock("./theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

describe("NotFoundPage", () => {
	it("shows the 404 flair, heading, and a link home", () => {
		render(
			<MemoryRouter>
				<NotFoundPage />
			</MemoryRouter>,
		);
		expect(screen.getByText("404")).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /page not found/iu })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /back to home/iu })).toHaveAttribute("href", "/");
	});
});
