import { render, screen } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Locale } from "../i18n/locales";
import ClerkAuthProvider from "./clerk-auth-provider";

const hoisted = vi.hoisted(() => ({
	locale: "en" as string,
	loaders: {} as Record<string, () => Promise<unknown>>,
	captureError: vi.fn(),
	providerProps: vi.fn(),
}));

vi.mock("@clerk/react", () => ({
	ClerkProvider: (props: { children: ReactNode; localization?: unknown }) => {
		hoisted.providerProps(props.localization);
		return <>{props.children}</>;
	},
	useAuth: () => ({ isLoaded: true, isSignedIn: false, getToken: vi.fn() }),
	useClerk: () => ({ user: null, signOut: vi.fn() }),
}));
vi.mock("@clerk/themes", () => ({ dark: {} }));
vi.mock("../api/client", () => ({ setTokenGetter: vi.fn() }));
vi.mock("../api/queries", () => ({ useMe: () => ({ data: undefined }) }));
vi.mock("../api/query-client", () => ({ queryClient: {} }));
vi.mock("../config-context", () => ({ useConfig: () => ({ clerkPublishableKey: "pk_test" }) }));
vi.mock("../router", () => ({ getAppRouter: () => ({ navigate: vi.fn() }) }));
vi.mock("../theme/theme-provider", () => ({ useTheme: () => ({ resolved: "light" }) }));
vi.mock("../sentry", () => ({
	captureError: (...args: unknown[]) => hoisted.captureError(...args),
}));
vi.mock("./use-clear-query-cache-on-user-change", () => ({
	useClearQueryCacheOnUserChange: vi.fn(),
}));
vi.mock("./use-identify-user-on-auth-change", () => ({ useIdentifyUserOnAuthChange: vi.fn() }));
vi.mock("./use-wipe-crdt-on-user-change", () => ({ useWipeCrdtOnUserChange: vi.fn() }));
vi.mock("../i18n/locale-provider", () => ({
	useT: () => ({ renderedLocale: hoisted.locale }),
}));
vi.mock("../i18n/vendor-locales", () => ({ clerkLocalizationLoaders: hoisted.loaders }));

const FRENCH = { locale: "fr-FR" };

function lastLocalization(): unknown {
	return hoisted.providerProps.mock.calls.at(-1)?.[0];
}

function mount(locale: Locale) {
	hoisted.locale = locale;
	return render(
		<ClerkAuthProvider>
			<p>child</p>
		</ClerkAuthProvider>,
	);
}

describe("ClerkAuthProvider localization", () => {
	beforeEach(() => {
		hoisted.providerProps.mockReset();
		hoisted.captureError.mockReset();
		for (const key of Object.keys(hoisted.loaders)) {
			delete hoisted.loaders[key];
		}
	});

	it("passes no localization for English and never loads one", () => {
		const load = vi.fn();
		hoisted.loaders.fr = load;
		mount("en");
		expect(screen.getByText("child")).toBeInTheDocument();
		expect(lastLocalization()).toBeUndefined();
		expect(load).not.toHaveBeenCalled();
	});

	it("passes the loaded localization once the loader resolves", async () => {
		hoisted.loaders.fr = async () => FRENCH;
		mount("fr");
		expect(hoisted.providerProps.mock.calls[0]?.[0]).toBeUndefined();
		await vi.waitFor(() => expect(lastLocalization()).toBe(FRENCH));
	});

	it("stays English and reports when the loader fails", async () => {
		const boom = new Error("chunk 404");
		hoisted.loaders.fr = async () => {
			throw boom;
		};
		mount("fr");
		await vi.waitFor(() => expect(hoisted.captureError).toHaveBeenCalledWith(boom));
		expect(lastLocalization()).toBeUndefined();
	});

	it("stays English without reporting when the loader resolves undefined", async () => {
		const load = vi.fn(() => Promise.resolve(undefined));
		hoisted.loaders.fr = load;
		mount("fr");
		await vi.waitFor(() => expect(load).toHaveBeenCalled());
		await Promise.resolve();
		expect(hoisted.captureError).not.toHaveBeenCalled();
		expect(lastLocalization()).toBeUndefined();
	});

	it("drops a stale load when the locale changes mid-flight", async () => {
		let release: () => void = () => undefined;
		const gate = new Promise<void>((resolve) => {
			release = resolve;
		});
		const GERMAN = { locale: "de-DE" };
		hoisted.loaders.fr = async () => {
			await gate;
			return FRENCH;
		};
		hoisted.loaders.de = async () => GERMAN;
		const view = mount("fr");
		hoisted.locale = "de";
		view.rerender(
			<ClerkAuthProvider>
				<p>child</p>
			</ClerkAuthProvider>,
		);
		await vi.waitFor(() => expect(lastLocalization()).toBe(GERMAN));
		release();
		await gate;
		await Promise.resolve();
		expect(lastLocalization()).toBe(GERMAN);
	});

	it("goes back to undefined when the locale returns to English", async () => {
		hoisted.loaders.fr = async () => FRENCH;
		const view = mount("fr");
		await vi.waitFor(() => expect(lastLocalization()).toBe(FRENCH));
		hoisted.locale = "en";
		view.rerender(
			<ClerkAuthProvider>
				<p>child</p>
			</ClerkAuthProvider>,
		);
		expect(lastLocalization()).toBeUndefined();
	});
});
