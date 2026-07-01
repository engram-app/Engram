import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import ErrorFallback from "./error-fallback";

afterEach(() => {
	vi.unstubAllEnvs();
	vi.restoreAllMocks();
});

describe("ErrorFallback", () => {
	it("renders the branded heading, reload action, and a plain home link", () => {
		render(<ErrorFallback error={new Error("boom")} />);

		expect(screen.getByRole("heading", { name: /something went wrong/iu })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /reload/iu })).toBeInTheDocument();
		// Plain anchor (not a router <Link>) — the fallback renders outside
		// RouterProvider, so it must navigate via href, not router context.
		expect(screen.getByRole("link", { name: /back to home/iu })).toHaveAttribute("href", "/");
	});

	it("renders the branded backdrop", () => {
		const { container } = render(<ErrorFallback error={new Error("boom")} />);
		expect(container.querySelector(".grid-overlay")).toBeInTheDocument();
	});

	it("shows the Sentry reference id only when reporting is active", () => {
		render(<ErrorFallback error={new Error("boom")} eventId="abc123" reported />);
		expect(screen.getByText(/abc123/u)).toBeInTheDocument();
	});

	it("omits the reference line when reporting is off, even with an event id", () => {
		render(<ErrorFallback error={new Error("boom")} eventId="abc123" reported={false} />);
		expect(screen.queryByText(/reference/iu)).not.toBeInTheDocument();
		expect(screen.queryByText(/abc123/u)).not.toBeInTheDocument();
	});

	it("claims the error was reported only when reporting is active", () => {
		const { rerender } = render(<ErrorFallback error={new Error("boom")} reported />);
		expect(screen.getByText(/has been reported/iu)).toBeInTheDocument();

		rerender(<ErrorFallback error={new Error("boom")} reported={false} />);
		expect(screen.queryByText(/has been reported/iu)).not.toBeInTheDocument();
	});

	it("reveals the error message in dev builds", () => {
		vi.stubEnv("DEV", true);
		render(<ErrorFallback error={new Error("kaboom-detail")} />);
		expect(screen.getByText(/kaboom-detail/u)).toBeInTheDocument();
	});

	it("hides the error message in production builds", () => {
		vi.stubEnv("DEV", false);
		render(<ErrorFallback error={new Error("kaboom-detail")} />);
		expect(screen.queryByText(/kaboom-detail/u)).not.toBeInTheDocument();
	});

	it("reloads the page when reload is clicked", () => {
		const reload = vi.fn();
		vi.spyOn(window.location, "reload").mockImplementation(reload);

		render(<ErrorFallback error={new Error("boom")} />);
		fireEvent.click(screen.getByRole("button", { name: /reload/iu }));

		expect(reload).toHaveBeenCalledOnce();
	});
});
