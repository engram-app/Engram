import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import AuthLayout from "./auth-layout";

describe("AuthLayout", () => {
	it("renders children and a language picker", () => {
		render(
			<AuthLayout>
				<p>card</p>
			</AuthLayout>,
		);
		expect(screen.getByText("card")).toBeInTheDocument();
		expect(screen.getByRole("combobox", { name: "Language" })).not.toHaveTextContent("English");
	});
});
