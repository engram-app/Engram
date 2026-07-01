import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import LoadingScreen from "./loading-screen";

describe("LoadingScreen", () => {
	it("renders an accessible loading status", () => {
		render(<LoadingScreen />);
		expect(screen.getByRole("status", { name: /loading/i })).toBeInTheDocument();
		expect(screen.getByText("Loading…")).toBeInTheDocument();
	});
});
