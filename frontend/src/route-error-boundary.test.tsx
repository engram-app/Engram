import { render, screen } from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import RouteErrorBoundary from "./route-error-boundary";

afterEach(() => vi.restoreAllMocks());

function Boom(): never {
	throw new Error("route exploded");
}

describe("RouteErrorBoundary", () => {
	it("renders the app ErrorFallback when a route throws, not RR's default page", async () => {
		// RR logs the caught route error to console.error; silence it so the test
		// output stays clean without hiding a real failure.
		vi.spyOn(console, "error").mockImplementation(() => {});
		const router = createMemoryRouter([
			{ path: "/", element: <Boom />, errorElement: <RouteErrorBoundary /> },
		]);
		render(<RouterProvider router={router} />);

		// The branded fallback — proves the route throw hit OUR boundary. RR's own
		// default "Unexpected Application Error" page has no such heading.
		expect(
			await screen.findByRole("heading", { name: /something went wrong/iu }),
		).toBeInTheDocument();
	});
});
