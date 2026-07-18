import { render, screen, waitFor } from "@testing-library/react";
import { createMemoryRouter, type RouteObject, RouterProvider } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RouteErrorBoundary from "./route-error-boundary";
import { captureError } from "./sentry";

// Mock the reporter so we can assert WHICH errors get reported without a real
// Sentry SDK. Default: "delivered nothing" (resolves undefined).
vi.mock("./sentry", () => ({ captureError: vi.fn(() => Promise.resolve(undefined)) }));
const mockCapture = vi.mocked(captureError);

beforeEach(() => {
	// RR logs caught route errors to console.error; silence it (without hiding a
	// real assertion failure).
	vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
	vi.restoreAllMocks();
	mockCapture.mockReset();
	mockCapture.mockResolvedValue(undefined);
});

function Boom(): never {
	throw new Error("route exploded");
}

function renderWithBoundary(route: RouteObject) {
	const router = createMemoryRouter([{ ...route, errorElement: <RouteErrorBoundary /> }]);
	return render(<RouterProvider router={router} />);
}

const heading = () => screen.findByRole("heading", { name: /something went wrong/iu });

describe("RouteErrorBoundary", () => {
	it("renders the app ErrorFallback when a route throws, not RR's default page", async () => {
		renderWithBoundary({ path: "/", element: <Boom /> });
		// The branded fallback — proves the route throw hit OUR boundary. RR's own
		// default "Unexpected Application Error" page has no such heading.
		expect(await heading()).toBeInTheDocument();
	});

	it("reports a plain route crash through captureError", async () => {
		renderWithBoundary({ path: "/", element: <Boom /> });
		await heading();
		expect(mockCapture).toHaveBeenCalledTimes(1);
		expect(mockCapture).toHaveBeenCalledWith(expect.any(Error));
	});

	it("does NOT report a 404 Response — an expected client error, not a crash", async () => {
		renderWithBoundary({
			path: "/",
			loader: () => {
				throw new Response("nope", { status: 404 });
			},
			element: <p>unused</p>,
		});
		await heading();
		expect(mockCapture).not.toHaveBeenCalled();
	});

	it("DOES report a 5xx Response — a real server failure", async () => {
		renderWithBoundary({
			path: "/",
			loader: () => {
				throw new Response("boom", { status: 503 });
			},
			element: <p>unused</p>,
		});
		await heading();
		expect(mockCapture).toHaveBeenCalledTimes(1);
	});

	it("claims 'reported' with a reference id only after delivery resolves an id", async () => {
		mockCapture.mockResolvedValue("evt-9");
		renderWithBoundary({ path: "/", element: <Boom /> });
		await heading();
		// The honest flags flip only once captureError resolves a (delivered) id.
		await waitFor(() => expect(screen.getByText(/has been reported/iu)).toBeInTheDocument());
		expect(screen.getByText(/evt-9/u)).toBeInTheDocument();
	});
});
