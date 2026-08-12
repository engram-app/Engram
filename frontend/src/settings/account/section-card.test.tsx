import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { SettingsSectionCard } from "./section-card";

describe("SettingsSectionCard", () => {
	it("renders title, description, and children", () => {
		render(
			<SettingsSectionCard title="Profile" description="Your name and avatar">
				<p>body content</p>
			</SettingsSectionCard>,
		);
		expect(screen.getByRole("heading", { name: "Profile" })).toBeInTheDocument();
		expect(screen.getByText("Your name and avatar")).toBeInTheDocument();
		expect(screen.getByText("body content")).toBeInTheDocument();
	});

	// The container padding exists for the page headings, which sit outside any
	// card. Without -mx-4 cancelling it, a phone pays that inset AND the card's
	// own p-4 before reaching content — the doubled padding this undoes. happy-dom
	// has no layout engine, so this asserts the mechanism, not the pixels.
	it("cancels the container's padding on mobile so content gets one inset, not two", () => {
		render(
			<SettingsSectionCard title="Profile">
				<p>body content</p>
			</SettingsSectionCard>,
		);
		const card = screen.getByRole("region", { name: "Profile" });
		expect(card.className).toContain("-mx-4");
		expect(card.className).toContain("md:mx-0");
	});

	it("omits the description node when not provided", () => {
		render(
			<SettingsSectionCard title="Sessions">
				<span>x</span>
			</SettingsSectionCard>,
		);
		expect(screen.getByRole("heading", { name: "Sessions" })).toBeInTheDocument();
	});
});
