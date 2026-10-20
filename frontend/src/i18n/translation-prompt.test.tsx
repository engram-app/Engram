import { render } from "@testing-library/react";
import type { ReactElement } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import zhCNCatalog from "./locale/zh-CN";
import type { CatalogLoaders } from "./locale-provider";
import type { Locale } from "./locales";
import type { Catalog } from "./translate";
import { offerLocaleSwitch } from "./translation-prompt";

const toast = vi.hoisted(() => vi.fn());
vi.mock("sonner", () => ({ toast }));

interface Button {
	label: ReactElement;
	onClick: () => void;
}
interface ToastOptions {
	action: Button;
	cancel: Button;
	onDismiss: () => void;
	onAutoClose: () => void;
}

function shown(): { message: ReactElement; options: ToastOptions } {
	const [message, options] = toast.mock.calls.at(-1) ?? [];
	return { message, options };
}

/** The rendered element: its text, and the attributes that keep a browser
 *  translator off it. */
function rendered(node: ReactElement): HTMLElement {
	const { container } = render(node);
	const el = container.firstElementChild;
	if (!(el instanceof HTMLElement)) {
		throw new Error("nothing rendered");
	}
	return el;
}

const zhCN: Catalog = zhCNCatalog;

function entry(key: string): string {
	const value = zhCN[key];
	if (typeof value !== "string") {
		throw new Error(`zh-CN lacks ${key}`);
	}
	return value;
}

// A user translating the page into a language we ship should get the real
// translation instead: offer it once, written in the language they chose.
describe("offerLocaleSwitch", () => {
	const setLocale = vi.fn<(next: Locale) => void>();
	const loaders: CatalogLoaders = {
		"zh-CN": async () => ({ default: zhCN }),
		de: async () => {
			throw new Error("chunk 404");
		},
	};
	const offer = (target: string, locale: Locale = "en") =>
		offerLocaleSwitch(target, { locale, setLocale, loaders });

	beforeEach(() => {
		window.localStorage.clear();
		toast.mockClear();
		setLocale.mockClear();
	});

	it("renders entirely from the target's catalog, untranslatable", async () => {
		await offer("zh-CN");

		expect(toast).toHaveBeenCalledOnce();
		const { message, options } = shown();
		const text = rendered(message);
		expect(text.textContent).toBe(
			entry("Show Engram in {language}?").replace("{language}", "简体中文"),
		);
		expect(text.getAttribute("translate")).toBe("no");
		expect(text.getAttribute("lang")).toBe("zh-CN");
		const action = rendered(options.action.label);
		expect(action.textContent).toBe(entry("Switch language"));
		expect(action.getAttribute("translate")).toBe("no");
		expect(rendered(options.cancel.label).textContent).toBe(entry("Not now"));

		options.action.onClick();
		expect(setLocale).toHaveBeenCalledWith("zh-CN");
	});

	it("falls back to English, not the current locale, when the target catalog fails", async () => {
		await offer("de-AT", "fr");
		expect(rendered(shown().message).textContent).toBe("Show Engram in Deutsch?");
		shown().options.action.onClick();
		expect(setLocale).toHaveBeenCalledWith("de");
	});

	it("does not offer the current locale", async () => {
		await offer("zh-CN", "zh-CN");
		expect(toast).not.toHaveBeenCalled();
	});

	it("does not offer an unsupported language", async () => {
		await offer("ar");
		expect(toast).not.toHaveBeenCalled();
	});

	// Two offers open at once (the translator switched target mid-session):
	// declining one must not erase the other's decline.
	it("keeps both declines when two open offers are declined", async () => {
		await offer("zh-CN");
		const first = shown().options;
		await offer("ja");
		const second = shown().options;
		first.cancel.onClick();
		second.cancel.onClick();
		toast.mockClear();

		await offer("zh-CN");
		await offer("ja");
		expect(toast).not.toHaveBeenCalled();
	});

	it.each([
		["Not now", (o: ToastOptions) => o.cancel.onClick()],
		["the close button", (o: ToastOptions) => o.onDismiss()],
		["the timeout", (o: ToastOptions) => o.onAutoClose()],
	])("never offers a language again after %s", async (_label, close) => {
		await offer("zh-CN");
		close(shown().options);
		toast.mockClear();

		await offer("zh-CN");
		expect(toast).not.toHaveBeenCalled();
		await offer("ja");
		expect(toast).toHaveBeenCalledOnce();
	});
});
