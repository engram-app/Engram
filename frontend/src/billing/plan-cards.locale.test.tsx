import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import de from "../i18n/locale/de";
import ru from "../i18n/locale/ru";
import { LocaleProvider } from "../i18n/locale-provider";
import { msg } from "../i18n/msg";
import { PlanCard } from "./plan-cards";

// The real catalogs: a translation once held the amount and decorated it with a
// currency of its own ("$5.83 руб./мес."), a false price on the checkout card.
function renderCard(code: "de" | "ru", catalog: object, cadence: "annual" | "monthly") {
	window.localStorage.setItem("engram:locale", code);
	render(
		<LocaleProvider loaders={{ [code]: async () => ({ default: catalog }) }}>
			<PlanCard
				name={msg("Starter")}
				cadence={cadence}
				monthlyPrice={7}
				annualPrice={70}
				features={[]}
				tier="starter"
				onAction={vi.fn()}
			/>
		</LocaleProvider>,
	);
}

describe("PlanCard prices in other locales", () => {
	afterEach(() => window.localStorage.clear());

	it("ru: the amount is a dollar amount Intl wrote, with no ruble", async () => {
		renderCard("ru", ru, "annual");
		const line = await screen.findByText(/5,83\s\$/u);
		expect(line.textContent).not.toMatch(/руб/u);
		expect(line.textContent).toContain(` · ${ru["billed yearly"]}`);
		expect(line.textContent).not.toMatch(/billed/u);
		expect(screen.getByText(/70\s\$/u).textContent).not.toMatch(/руб/u);
	});

	it("de: the amount is a dollar amount Intl wrote, with no euro", async () => {
		renderCard("de", de, "monthly");
		const line = await screen.findByText(/84\s\$/u);
		expect(line.textContent).not.toMatch(/€/u);
		expect(line.textContent).toContain(` · ${de["billed monthly"]}`);
		expect(line.textContent).not.toMatch(/billed/u);
		expect(screen.getByText(/7\s\$/u).textContent).not.toMatch(/€/u);
	});
});
