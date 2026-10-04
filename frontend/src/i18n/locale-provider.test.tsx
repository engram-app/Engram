import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type CatalogLoaders, LocaleProvider, useT } from "./locale-provider";

const captureError = vi.fn();
vi.mock("../sentry", () => ({ captureError: (...args: unknown[]) => captureError(...args) }));

function Probe() {
	const { t, tn, locale, setLocale } = useT();
	return (
		<>
			<p>{t("Hello {name}", { name: "Todd" })}</p>
			<p>{tn({ one: "{count} file", other: "{count} files" }, 2)}</p>
			<output>{locale}</output>
			<button type="button" onClick={() => setLocale("en")}>
				english
			</button>
			<button type="button" onClick={() => setLocale("fr")}>
				french
			</button>
		</>
	);
}

const de = async () => ({ default: { "Hello {name}": "Hallo {name}" } });

function mount(loaders: CatalogLoaders) {
	return render(
		<LocaleProvider loaders={loaders}>
			<Probe />
		</LocaleProvider>,
	);
}

describe("LocaleProvider", () => {
	beforeEach(() => {
		window.localStorage.clear();
		document.documentElement.lang = "en";
		captureError.mockReset();
	});
	afterEach(() => vi.restoreAllMocks());

	it("renders English with no provider", () => {
		render(<Probe />);
		expect(screen.getByText("Hello Todd")).toBeInTheDocument();
		expect(screen.getByText("2 files")).toBeInTheDocument();
	});

	it("uses the stored locale, ahead of the browser language", async () => {
		window.localStorage.setItem("engram:locale", "de");
		vi.spyOn(navigator, "languages", "get").mockReturnValue(["fr-FR"]);
		mount({ de });
		expect(await screen.findByText("Hallo Todd")).toBeInTheDocument();
		expect(document.documentElement.lang).toBe("de");
	});

	it("falls back to navigator.languages when nothing is stored", async () => {
		vi.spyOn(navigator, "languages", "get").mockReturnValue(["de-DE"]);
		mount({ de });
		expect(await screen.findByText("Hallo Todd")).toBeInTheDocument();
	});

	it("shows English until the catalog resolves", async () => {
		window.localStorage.setItem("engram:locale", "de");
		let release: () => void = () => undefined;
		const gate = new Promise<void>((resolve) => {
			release = resolve;
		});
		mount({
			de: async () => {
				await gate;
				return de();
			},
		});
		expect(screen.getByText("Hello Todd")).toBeInTheDocument();
		await act(async () => release());
		expect(await screen.findByText("Hallo Todd")).toBeInTheDocument();
	});

	it("setLocale persists, updates <html lang>, and swaps back to English", async () => {
		window.localStorage.setItem("engram:locale", "de");
		mount({ de });
		await screen.findByText("Hallo Todd");
		await act(async () => screen.getByRole("button", { name: "english" }).click());
		expect(screen.getByText("Hello Todd")).toBeInTheDocument();
		expect(window.localStorage.getItem("engram:locale")).toBe("en");
		expect(document.documentElement.lang).toBe("en");
	});

	it("stays English and reports when a catalog fails to load", async () => {
		window.localStorage.setItem("engram:locale", "de");
		const boom = new Error("chunk 404");
		mount({
			de: async () => {
				throw boom;
			},
		});
		await vi.waitFor(() => expect(captureError).toHaveBeenCalledWith(boom));
		expect(screen.getByText("Hello Todd")).toBeInTheDocument();
	});

	it("drops a stale load when the locale changes mid-flight", async () => {
		window.localStorage.setItem("engram:locale", "de");
		let release: () => void = () => undefined;
		const gate = new Promise<void>((resolve) => {
			release = resolve;
		});
		mount({
			de: async () => {
				await gate;
				return de();
			},
			fr: async () => ({ default: { "Hello {name}": "Bonjour {name}" } }),
		});
		await act(async () => screen.getByRole("button", { name: "french" }).click());
		expect(await screen.findByText("Bonjour Todd")).toBeInTheDocument();
		await act(async () => release());
		expect(screen.getByText("Bonjour Todd")).toBeInTheDocument();
	});
});
