import { act, render, screen } from "@testing-library/react";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type CatalogLoaders, LocaleProvider, useStableT, useT } from "./locale-provider";

const captureError = vi.fn();
vi.mock("../sentry", () => ({ captureError: (...args: unknown[]) => captureError(...args) }));

function Probe() {
	const { t, tn, locale, renderedLocale, setLocale } = useT();
	return (
		<>
			<p>{t("Hello {name}", { name: "Todd" })}</p>
			<p>{tn({ one: "{count} file", other: "{count} files" }, 2)}</p>
			<output>{locale}</output>
			<output aria-label="rendered">{renderedLocale}</output>
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

	it("sets <html lang> only once a non-empty catalog is rendered", async () => {
		window.localStorage.setItem("engram:locale", "de");
		mount({ de });
		expect(document.documentElement.lang).toBe("en");
		await screen.findByText("Hallo Todd");
		expect(document.documentElement.lang).toBe("de");
	});

	it("keeps <html lang> en when the loaded catalog is empty", async () => {
		window.localStorage.setItem("engram:locale", "de");
		const load = vi.fn(async () => ({ default: {} }));
		mount({ de: load });
		await vi.waitFor(() => expect(load).toHaveBeenCalled());
		await act(async () => undefined);
		expect(document.documentElement.lang).toBe("en");
	});

	it("keeps <html lang> en when the catalog fails to load", async () => {
		window.localStorage.setItem("engram:locale", "de");
		mount({
			de: async () => {
				throw new Error("chunk 404");
			},
		});
		await vi.waitFor(() => expect(captureError).toHaveBeenCalled());
		expect(document.documentElement.lang).toBe("en");
	});

	it("stays English without reporting when the loader resolves undefined", async () => {
		window.localStorage.setItem("engram:locale", "de");
		const load = vi.fn(() => Promise.resolve(undefined));
		mount({ de: load });
		await vi.waitFor(() => expect(load).toHaveBeenCalled());
		await act(async () => undefined);
		expect(captureError).not.toHaveBeenCalled();
		expect(screen.getByText("Hello Todd")).toBeInTheDocument();
	});

	describe("renderedLocale", () => {
		const rendered = () => screen.getByLabelText("rendered").textContent;

		it("is en with no provider", () => {
			render(<Probe />);
			expect(rendered()).toBe("en");
		});

		it("is en while loading and for an empty catalog", async () => {
			window.localStorage.setItem("engram:locale", "de");
			const load = vi.fn(async () => ({ default: {} }));
			mount({ de: load });
			expect(rendered()).toBe("en");
			await vi.waitFor(() => expect(load).toHaveBeenCalled());
			await act(async () => undefined);
			expect(rendered()).toBe("en");
		});

		it("is en after a failed load", async () => {
			window.localStorage.setItem("engram:locale", "de");
			mount({
				de: async () => {
					throw new Error("chunk 404");
				},
			});
			await vi.waitFor(() => expect(captureError).toHaveBeenCalled());
			expect(rendered()).toBe("en");
		});

		it("is the locale once a non-empty catalog is loaded", async () => {
			window.localStorage.setItem("engram:locale", "de");
			mount({ de });
			await screen.findByText("Hallo Todd");
			expect(rendered()).toBe("de");
		});
	});
});

describe("useStableT", () => {
	beforeEach(() => {
		window.localStorage.clear();
		window.localStorage.setItem("engram:locale", "de");
	});

	it("keeps t and tn identities across a catalog load and a locale switch, but follows the output", async () => {
		const seen: { t: unknown; tn: unknown }[] = [];
		function Stable() {
			const stable = useStableT();
			const { t, setLocale } = useT();
			const [later, setLater] = useState("");
			seen.push({ t: stable.t, tn: stable.tn });
			return (
				<>
					<p>{t("Hello {name}", { name: "Todd" })}</p>
					<button type="button" onClick={() => setLocale("fr")}>
						french
					</button>
					<button type="button" onClick={() => setLater(stable.t("Hello {name}", { name: "Ann" }))}>
						later
					</button>
					<output aria-label="later">{later}</output>
				</>
			);
		}
		render(
			<LocaleProvider
				loaders={{
					de,
					fr: async () => ({ default: { "Hello {name}": "Bonjour {name}" } }),
				}}
			>
				<Stable />
			</LocaleProvider>,
		);
		expect(screen.getByText("Hello Todd")).toBeInTheDocument();
		expect(await screen.findByText("Hallo Todd")).toBeInTheDocument();
		await act(async () => screen.getByRole("button", { name: "french" }).click());
		expect(await screen.findByText("Bonjour Todd")).toBeInTheDocument();
		await act(async () => screen.getByRole("button", { name: "later" }).click());
		expect(screen.getByLabelText("later")).toHaveTextContent("Bonjour Ann");
		expect(seen.length).toBeGreaterThan(2);
		expect(new Set(seen.map((s) => s.t)).size).toBe(1);
		expect(new Set(seen.map((s) => s.tn)).size).toBe(1);
	});
});
