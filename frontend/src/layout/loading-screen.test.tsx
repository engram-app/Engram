import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import LoadingScreen from "./loading-screen";

describe("LoadingScreen", () => {
	it("renders an accessible loading status", () => {
		render(<LoadingScreen />);
		expect(screen.getByRole("status", { name: /loading/iu })).toBeInTheDocument();
		expect(screen.getByText("Loading…")).toBeInTheDocument();
	});
});
