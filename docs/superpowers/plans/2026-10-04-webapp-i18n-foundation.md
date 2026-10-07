# Web app i18n: slice 1 (foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hand-rolled, English-as-key i18n core to the SPA with detection, a language switcher, and a key-integrity test, proven on one surface.

**Architecture:** `src/i18n/` holds pure functions (`locales`, `storage`, `translate`), a `LocaleProvider` that lazy-loads one catalog chunk per locale, and a `useT()` hook. The context default is an English identity, so unwrapped components and existing tests keep working. Catalogs are empty stubs in this slice.

**Tech Stack:** React 19, Vite 8 (`import.meta.glob`), Vitest 4 + Testing Library + happy-dom, Biome. No new dependency.

**Spec:** Engram vault, `50 Engineering/_Superpowers Specs/2026-10-04-webapp-i18n-design.md`

## Global Constraints

- All work is under `backend/frontend/`, in worktree `.worktrees/webapp-i18n`, branch `feat/webapp-i18n-foundation`.
- Locales: `en` plus `de es fr it ja ko pt-BR ru zh-CN zh-TW`. No `en` catalog file.
- The English string is the key. A missing key falls through to English.
- No new dependency. No URL locale prefix.
- No module-scope `t()`. Translation is reachable only through `useT()` / `<Trans>`.
- Storage key: `engram:locale`. Detection order: stored pick, `navigator.languages`, `en`.
- Use `bun` / `bunx`, never `npm`. Run gates unpiped (`bun run check`, `bunx tsc --noEmit`, `bunx vitest run`).
- Tabs for indentation (Biome). No version bumps. Commits are conventional and carry the attribution trailer from the session.
- Markup: semantic HTML, no `div`, Fragments where possible.

## Review Focus

- `navigator.languages` is empty or contains `""`: resolves to `en`, never throws. (Task 1)
- Stored locale is garbage or `localStorage` throws (private mode): ignored, detection continues. (Task 1)
- `zh-Hant-HK` must reach `zh-TW`, bare `zh` and `zh-Hans` reach `zh-CN`, `pt-PT` reaches `pt-BR`. (Task 1)
- Catalog chunk fails to load (stale deploy, offline): UI stays English and the error is reported. (Task 3)
- Locale switch while a slow catalog load is in flight: the stale load must not overwrite the newer locale. (Task 3)
- Russian plural (`one/few/many`) and Japanese (single form) pick the right template. (Task 2)
- A translation that drops a `{placeholder}` or a locale holding a key no call site uses fails CI. (Task 4)

---

### Task 1: Locale list, matching, and storage

**Files:**
- Create: `frontend/src/i18n/locales.ts`
- Create: `frontend/src/i18n/storage.ts`
- Test: `frontend/src/i18n/locales.test.ts`
- Test: `frontend/src/i18n/storage.test.ts`

**Interfaces:**
- Produces: `LOCALES`, `type Locale`, `LOCALE_NAMES: Record<Locale, string>`, `matchLocale(tag: string): Locale | null`, `resolveLocale(languages: readonly string[]): Locale`, `getStoredLocale(): Locale | null`, `setStoredLocale(locale: Locale): void`.

- [ ] **Step 1: Write the failing tests**

`frontend/src/i18n/locales.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { matchLocale, resolveLocale } from "./locales";

describe("matchLocale", () => {
	it.each([
		["de-DE", "de"],
		["DE", "de"],
		["pt-br", "pt-BR"],
		["pt-PT", "pt-BR"],
		["pt", "pt-BR"],
		["zh", "zh-CN"],
		["zh-Hans", "zh-CN"],
		["zh-SG", "zh-CN"],
		["zh-TW", "zh-TW"],
		["zh-HK", "zh-TW"],
		["zh-Hant-HK", "zh-TW"],
		["en-GB", "en"],
		["ja-JP", "ja"],
	])("%s -> %s", (tag, expected) => {
		expect(matchLocale(tag)).toBe(expected);
	});

	it.each(["xx", "", "-", "klingon"])("rejects %j", (tag) => {
		expect(matchLocale(tag)).toBeNull();
	});
});

describe("resolveLocale", () => {
	it("takes the first supported tag", () => {
		expect(resolveLocale(["xx", "fr-CA", "de"])).toBe("fr");
	});
	it("falls back to en for an empty list", () => {
		expect(resolveLocale([])).toBe("en");
	});
	it("falls back to en when nothing matches", () => {
		expect(resolveLocale(["", "xx"])).toBe("en");
	});
});
```

`frontend/src/i18n/storage.test.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStoredLocale, setStoredLocale } from "./storage";

describe("locale storage", () => {
	beforeEach(() => window.localStorage.clear());
	afterEach(() => vi.restoreAllMocks());

	it("round-trips a valid locale", () => {
		setStoredLocale("ja");
		expect(getStoredLocale()).toBe("ja");
	});
	it("returns null when nothing is stored", () => {
		expect(getStoredLocale()).toBeNull();
	});
	it("ignores an unknown stored value", () => {
		window.localStorage.setItem("engram:locale", "klingon");
		expect(getStoredLocale()).toBeNull();
	});
	it("returns null when localStorage throws", () => {
		vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
			throw new Error("denied");
		});
		expect(getStoredLocale()).toBeNull();
	});
	it("does not throw when localStorage write throws", () => {
		vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
			throw new Error("denied");
		});
		expect(() => setStoredLocale("de")).not.toThrow();
	});
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/frontend && bunx vitest run src/i18n/locales.test.ts src/i18n/storage.test.ts`
Expected: FAIL, modules not found.

- [ ] **Step 3: Write minimal implementation**

`frontend/src/i18n/locales.ts`:

```ts
export const LOCALES = [
	"en",
	"de",
	"es",
	"fr",
	"it",
	"ja",
	"ko",
	"pt-BR",
	"ru",
	"zh-CN",
	"zh-TW",
] as const;
export type Locale = (typeof LOCALES)[number];

// Endonyms: a language must be findable in its own script. Never translated.
export const LOCALE_NAMES: Record<Locale, string> = {
	en: "English",
	de: "Deutsch",
	es: "Español",
	fr: "Français",
	it: "Italiano",
	ja: "日本語",
	ko: "한국어",
	"pt-BR": "Português (Brasil)",
	ru: "Русский",
	"zh-CN": "简体中文",
	"zh-TW": "繁體中文",
};

const BY_LOWER = new Map<string, Locale>(LOCALES.map((l) => [l.toLowerCase(), l]));
const TRADITIONAL = /^zh-(tw|hk|mo|hant)/u;

export function matchLocale(tag: string): Locale | null {
	const lower = tag.toLowerCase();
	const exact = BY_LOWER.get(lower);
	if (exact) {
		return exact;
	}
	if (TRADITIONAL.test(lower)) {
		return "zh-TW";
	}
	const base = lower.split("-")[0] ?? "";
	if (base === "zh") {
		return "zh-CN";
	}
	if (base === "pt") {
		return "pt-BR";
	}
	return BY_LOWER.get(base) ?? null;
}

export function resolveLocale(languages: readonly string[]): Locale {
	for (const tag of languages) {
		const match = matchLocale(tag);
		if (match) {
			return match;
		}
	}
	return "en";
}
```

`frontend/src/i18n/storage.ts`:

```ts
import { isMember } from "../lib/is-member";
import { LOCALES, type Locale } from "./locales";

const KEY = "engram:locale";

export function getStoredLocale(): Locale | null {
	try {
		const raw = window.localStorage.getItem(KEY);
		if (isMember(LOCALES, raw)) {
			return raw;
		}
	} catch {
		// localStorage may throw in private mode or sandboxed contexts
	}
	return null;
}

export function setStoredLocale(locale: Locale): void {
	try {
		window.localStorage.setItem(KEY, locale);
	} catch {
		// best-effort; the pick still applies for this session
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend/frontend && bunx vitest run src/i18n/locales.test.ts src/i18n/storage.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/i18n
git commit -m "feat(i18n): locale list, matching and storage"
```

---

### Task 2: Translate and plural functions

**Files:**
- Create: `frontend/src/i18n/translate.ts`
- Test: `frontend/src/i18n/translate.test.ts`

**Interfaces:**
- Consumes: `Locale` from `./locales`.
- Produces: `type PluralForms`, `type Catalog`, `type Vars`, `interpolate(template, vars?)`, `translate(catalog, en, vars?)`, `translatePlural(catalog, locale, en, count, vars?)` where `en` is `PluralForms & { other: string }`. The catalog key for a plural is `en.other`.

- [ ] **Step 1: Write the failing test**

`frontend/src/i18n/translate.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { interpolate, translate, translatePlural } from "./translate";

const EN_FILES = { one: "{count} file", other: "{count} files" };

describe("interpolate", () => {
	it("fills named placeholders", () => {
		expect(interpolate("Hi {name}", { name: "Todd" })).toBe("Hi Todd");
	});
	it("leaves an unknown placeholder visible", () => {
		expect(interpolate("Hi {name}", {})).toBe("Hi {name}");
	});
	it("returns the template when there are no vars", () => {
		expect(interpolate("Hi {name}")).toBe("Hi {name}");
	});
});

describe("translate", () => {
	it("uses the catalog entry", () => {
		expect(translate({ "Hello {n}": "Hallo {n}" }, "Hello {n}", { n: 1 })).toBe("Hallo 1");
	});
	it("falls through to English on a missing key", () => {
		expect(translate({}, "Hello {n}", { n: 1 })).toBe("Hello 1");
	});
	it("ignores a plural entry stored under a string key", () => {
		expect(translate({ Hello: { other: "x" } }, "Hello")).toBe("Hello");
	});
});

describe("translatePlural", () => {
	it("falls through to English forms with English plural rules", () => {
		expect(translatePlural({}, "ru", EN_FILES, 1)).toBe("1 file");
		expect(translatePlural({}, "ru", EN_FILES, 2)).toBe("2 files");
	});
	it("uses Russian one/few/many", () => {
		const catalog = {
			"{count} files": {
				one: "{count} файл",
				few: "{count} файла",
				many: "{count} файлов",
				other: "{count} файла",
			},
		};
		expect(translatePlural(catalog, "ru", EN_FILES, 1)).toBe("1 файл");
		expect(translatePlural(catalog, "ru", EN_FILES, 3)).toBe("3 файла");
		expect(translatePlural(catalog, "ru", EN_FILES, 5)).toBe("5 файлов");
		expect(translatePlural(catalog, "ru", EN_FILES, 21)).toBe("21 файл");
	});
	it("handles a single-form language", () => {
		const catalog = { "{count} files": { other: "{count}個のファイル" } };
		expect(translatePlural(catalog, "ja", EN_FILES, 1)).toBe("1個のファイル");
		expect(translatePlural(catalog, "ja", EN_FILES, 0)).toBe("0個のファイル");
	});
	it("does not let vars override count", () => {
		expect(translatePlural({}, "en", EN_FILES, 2, { count: 99 })).toBe("2 files");
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bunx vitest run src/i18n/translate.test.ts`
Expected: FAIL, module not found.

- [ ] **Step 3: Write minimal implementation**

`frontend/src/i18n/translate.ts`:

```ts
import type { Locale } from "./locales";

export type PluralForms = Partial<Record<Intl.LDMLPluralRule, string>>;
export type Catalog = Record<string, string | PluralForms>;
export type Vars = Record<string, string | number>;

const PLACEHOLDER = /\{(\w+)\}/gu;

export function interpolate(template: string, vars?: Vars): string {
	if (!vars) {
		return template;
	}
	return template.replace(PLACEHOLDER, (match, name: string) =>
		name in vars ? String(vars[name]) : match,
	);
}

export function translate(catalog: Catalog, en: string, vars?: Vars): string {
	const hit = catalog[en];
	return interpolate(typeof hit === "string" ? hit : en, vars);
}

// The catalog key for a counted string is its English `other` form.
export function translatePlural(
	catalog: Catalog,
	locale: Locale,
	en: PluralForms & { other: string },
	count: number,
	vars?: Vars,
): string {
	const hit = catalog[en.other];
	const translated = typeof hit === "object";
	const forms = translated ? hit : en;
	const category = new Intl.PluralRules(translated ? locale : "en").select(count);
	return interpolate(forms[category] ?? forms.other ?? en.other, { ...vars, count });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bunx vitest run src/i18n/translate.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/i18n/translate.ts frontend/src/i18n/translate.test.ts
git commit -m "feat(i18n): translate and plural functions"
```

---

### Task 3: LocaleProvider, useT, Trans

**Files:**
- Create: `frontend/src/i18n/locale-provider.tsx`
- Create: `frontend/src/i18n/trans.tsx`
- Test: `frontend/src/i18n/locale-provider.test.tsx`
- Test: `frontend/src/i18n/trans.test.tsx`

**Interfaces:**
- Consumes: Tasks 1 and 2 (`resolveLocale`, `getStoredLocale`, `setStoredLocale`, `translate`, `translatePlural`, `Catalog`, `Vars`, `PluralForms`), `captureError` from `../sentry`.
- Produces: `type CatalogLoaders`, `LocaleProvider({ children, loaders? })`, `useT(): { locale, setLocale, t, tn }`, `Trans({ text, slots })`. `useT()` outside a provider returns an English identity (no throw).

- [ ] **Step 1: Write the failing tests**

`frontend/src/i18n/locale-provider.test.tsx`:

```tsx
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
```

`frontend/src/i18n/trans.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LocaleProvider } from "./locale-provider";
import { Trans } from "./trans";

describe("Trans", () => {
	it("renders English around a React slot", () => {
		render(<Trans text="Type {word} to confirm" slots={{ word: <code>delete</code> }} />);
		expect(screen.getByText("delete").tagName).toBe("CODE");
		expect(document.body.textContent).toBe("Type delete to confirm");
	});

	it("moves the slot where the translation puts it", async () => {
		window.localStorage.setItem("engram:locale", "ja");
		const loaders = {
			ja: async () => ({ default: { "Type {word} to confirm": "{word}を入力して確認" } }),
		};
		render(
			<LocaleProvider loaders={loaders}>
				<Trans text="Type {word} to confirm" slots={{ word: <code>delete</code> }} />
			</LocaleProvider>,
		);
		await screen.findByText("delete");
		await expect.poll(() => document.body.textContent).toBe("deleteを入力して確認");
	});

	it("keeps an unfilled slot visible", () => {
		render(<Trans text="Hi {who}" slots={{}} />);
		expect(document.body.textContent).toBe("Hi {who}");
	});
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/frontend && bunx vitest run src/i18n/locale-provider.test.tsx src/i18n/trans.test.tsx`
Expected: FAIL, modules not found.

- [ ] **Step 3: Write minimal implementation**

`frontend/src/i18n/locale-provider.tsx`:

```tsx
import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useState,
} from "react";
import { captureError } from "../sentry";
import { type Locale, resolveLocale } from "./locales";
import { getStoredLocale, setStoredLocale } from "./storage";
import {
	type Catalog,
	type PluralForms,
	translate,
	translatePlural,
	type Vars,
} from "./translate";

export type CatalogLoaders = Partial<Record<Locale, () => Promise<{ default: Catalog }>>>;

// Vite splits each catalog into its own lazy chunk; `en` has no file.
const defaultLoaders = Object.fromEntries(
	Object.entries(import.meta.glob<{ default: Catalog }>("./locale/*.ts")).map(([path, load]) => [
		path.slice("./locale/".length, -".ts".length),
		load,
	]),
) as CatalogLoaders;

type PluralEn = PluralForms & { other: string };

interface LocaleContextValue {
	locale: Locale;
	setLocale: (next: Locale) => void;
	t: (en: string, vars?: Vars) => string;
	tn: (en: PluralEn, count: number, vars?: Vars) => string;
}

// Un-wrapped trees (and the tests that predate i18n) get English, not a throw:
// an untranslated string is the designed fallback, not an error.
const ENGLISH: LocaleContextValue = {
	locale: "en",
	setLocale: () => undefined,
	t: (en, vars) => translate({}, en, vars),
	tn: (en, count, vars) => translatePlural({}, "en", en, count, vars),
};

const LocaleContext = createContext<LocaleContextValue>(ENGLISH);

export function LocaleProvider({
	children,
	loaders = defaultLoaders,
}: {
	children: ReactNode;
	loaders?: CatalogLoaders;
}) {
	const [locale, setLocaleState] = useState<Locale>(
		() => getStoredLocale() ?? resolveLocale(navigator.languages),
	);
	const [catalog, setCatalog] = useState<Catalog>({});

	useEffect(() => {
		document.documentElement.lang = locale;
		const load = loaders[locale];
		if (!load) {
			setCatalog({});
			return;
		}
		let current = true;
		load()
			.then((mod) => {
				if (current) {
					setCatalog(mod.default);
				}
			})
			.catch((error: unknown) => {
				// Stale deploy or offline: keep the English fallback, but report it.
				void captureError(error);
				if (current) {
					setCatalog({});
				}
			});
		return () => {
			current = false;
		};
	}, [locale, loaders]);

	const setLocale = useCallback((next: Locale) => {
		setStoredLocale(next);
		setLocaleState(next);
	}, []);

	const value = useMemo<LocaleContextValue>(
		() => ({
			locale,
			setLocale,
			t: (en, vars) => translate(catalog, en, vars),
			tn: (en, count, vars) => translatePlural(catalog, locale, en, count, vars),
		}),
		[locale, setLocale, catalog],
	);
	return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

export function useT(): LocaleContextValue {
	return useContext(LocaleContext);
}
```

`frontend/src/i18n/trans.tsx`:

```tsx
import { Fragment, type ReactNode } from "react";
import { useT } from "./locale-provider";

// Renders one translated sentence around React children, so a styled span or
// link can sit anywhere the target language needs it. Slot names must be
// unique within one sentence.
export function Trans({ text, slots }: { text: string; slots: Record<string, ReactNode> }) {
	const { t } = useT();
	// split() with a capture group puts slot names at odd indexes.
	const parts = t(text).split(/\{(\w+)\}/u);
	return (
		<>
			{parts.map((part, index) =>
				index % 2 === 0 ? (
					part
				) : (
					<Fragment key={part}>{slots[part] ?? `{${part}}`}</Fragment>
				),
			)}
		</>
	);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend/frontend && bunx vitest run src/i18n`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/i18n
git commit -m "feat(i18n): LocaleProvider, useT and Trans"
```

---

### Task 4: Stub catalogs and the key-integrity test

**Files:**
- Create: `frontend/src/i18n/locale/{de,es,fr,it,ja,ko,pt-BR,ru,zh-CN,zh-TW}.ts` (ten identical stubs)
- Test: `frontend/src/i18n/keys.test.ts`

**Interfaces:**
- Consumes: `Catalog` from `../translate`.
- Produces: the CI guard. Three checks: (1) a catalog key no call site uses (orphan), (2) a translation whose `{placeholders}` do not match its key, (3) a key present in some locales but missing from others. Call sites scanned: `t("…")`, `tn({ …, other: "…" }, …)`, `<Trans text="…">`.

- [ ] **Step 1: Write the failing test**

`frontend/src/i18n/keys.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { Catalog } from "./translate";

const T_CALL = /\bt\(\s*"((?:[^"\\]|\\.)*)"/gu;
const TN_CALL = /\btn\(\s*\{[^}]*?\bother:\s*"((?:[^"\\]|\\.)*)"/gu;
const TRANS_PROP = /<Trans\s[^>]*?\btext="((?:[^"\\]|\\.)*)"/gu;
const TOKEN = /\{(\w+)\}/gu;

function tokens(text: string): Set<string> {
	return new Set([...text.matchAll(TOKEN)].map((m) => m[1] ?? ""));
}

export function usedKeys(sources: readonly string[]): Set<string> {
	const keys = new Set<string>();
	for (const source of sources) {
		for (const re of [T_CALL, TN_CALL, TRANS_PROP]) {
			for (const match of source.matchAll(re)) {
				keys.add(JSON.parse(`"${match[1] ?? ""}"`) as string);
			}
		}
	}
	return keys;
}

export function findProblems(used: Set<string>, catalogs: Record<string, Catalog>): string[] {
	const problems: string[] = [];
	const everyKey = new Set(Object.values(catalogs).flatMap((c) => Object.keys(c)));
	for (const [locale, catalog] of Object.entries(catalogs)) {
		for (const [key, value] of Object.entries(catalog)) {
			if (!used.has(key)) {
				problems.push(`${locale}: orphan key ${JSON.stringify(key)}`);
			}
			const want = tokens(key);
			const forms = typeof value === "string" ? [value] : Object.values(value);
			for (const form of forms) {
				const got = tokens(form);
				const dropped = typeof value === "string" && [...want].some((x) => !got.has(x));
				const invented = [...got].some((x) => !want.has(x));
				if (dropped || invented) {
					problems.push(`${locale}: placeholder mismatch in ${JSON.stringify(key)}`);
				}
			}
		}
		for (const key of everyKey) {
			if (!(key in catalog)) {
				problems.push(`${locale}: missing key ${JSON.stringify(key)}`);
			}
		}
	}
	return problems;
}

describe("findProblems (self-check)", () => {
	const used = new Set(["Hello {name}", "{count} files"]);
	it("passes a clean catalog set", () => {
		const catalogs = {
			de: { "Hello {name}": "Hallo {name}" },
			fr: { "Hello {name}": "Bonjour {name}" },
		};
		expect(findProblems(used, catalogs)).toEqual([]);
	});
	it("flags an orphan key", () => {
		expect(findProblems(used, { de: { Typo: "x" } })).toEqual(['de: orphan key "Typo"']);
	});
	it("flags a dropped placeholder", () => {
		expect(findProblems(used, { de: { "Hello {name}": "Hallo" } })).toEqual([
			'de: placeholder mismatch in "Hello {name}"',
		]);
	});
	it("flags an invented placeholder", () => {
		expect(findProblems(used, { de: { "Hello {name}": "Hallo {who}" } })).toEqual([
			'de: placeholder mismatch in "Hello {name}"',
		]);
	});
	it("lets a plural form omit {count} but not invent one", () => {
		expect(
			findProblems(used, { ja: { "{count} files": { one: "1 file", other: "{count} files" } } }),
		).toEqual([]);
		expect(findProblems(used, { ja: { "{count} files": { other: "{n} files" } } })).toHaveLength(1);
	});
	it("flags a key missing from another locale", () => {
		const catalogs = { de: { "Hello {name}": "Hallo {name}" }, fr: {} };
		expect(findProblems(used, catalogs)).toEqual(['fr: missing key "Hello {name}"']);
	});
});

describe("usedKeys (self-check)", () => {
	it("finds t(), tn() and Trans keys, including escapes", () => {
		const src = `
			t("Hello {name}", { name })
			tn({ one: "{count} file", other: "{count} files" }, n)
			<Trans text="Type {w}" slots={{}} />
			t("Say \\"hi\\"")
		`;
		expect([...usedKeys([src])].sort()).toEqual(
			['Hello {name}', '{count} files', 'Type {w}', 'Say "hi"'].sort(),
		);
	});
});

describe("repo catalogs", () => {
	const sources = Object.values(
		import.meta.glob<string>(["../**/*.{ts,tsx}", "!../**/*.test.*", "!../i18n/locale/**"], {
			query: "?raw",
			import: "default",
			eager: true,
		}),
	);
	const catalogs = Object.fromEntries(
		Object.entries(import.meta.glob<{ default: Catalog }>("./locale/*.ts", { eager: true })).map(
			([path, mod]) => [path.slice("./locale/".length, -".ts".length), mod.default],
		),
	);

	it("ships a catalog for every non-English locale", () => {
		expect(Object.keys(catalogs).sort()).toEqual(
			["de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "zh-CN", "zh-TW"].sort(),
		);
	});
	it("has no orphan keys, dropped placeholders, or cross-locale gaps", () => {
		expect(findProblems(usedKeys(sources), catalogs)).toEqual([]);
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bunx vitest run src/i18n/keys.test.ts`
Expected: FAIL on "ships a catalog for every non-English locale" (no catalog files yet). The self-check suites pass.

- [ ] **Step 3: Create the ten stubs**

Each of `de es fr it ja ko pt-BR ru zh-CN zh-TW` gets `frontend/src/i18n/locale/<code>.ts`:

```ts
import type { Catalog } from "../translate";

// Filled in per surface (slice 4). Empty falls through to English.
export default {} satisfies Catalog;
```

Create them in one command:

```bash
cd backend/frontend/src/i18n && mkdir -p locale && for c in de es fr it ja ko pt-BR ru zh-CN zh-TW; do
printf '%s\n' 'import type { Catalog } from "../translate";' '' '// Filled in per surface (slice 4). Empty falls through to English.' 'export default {} satisfies Catalog;' > "locale/$c.ts"; done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bunx vitest run src/i18n`
Expected: PASS, all i18n suites.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/i18n
git commit -m "feat(i18n): stub catalogs and key-integrity test"
```

---

### Task 5: Wire the provider, switcher, and proof surface; docs

**Files:**
- Modify: `frontend/src/main.tsx` (wrap inside `ThemeProvider`, lines ~108-123, add import)
- Modify: `frontend/src/settings/account/appearance-section.tsx`
- Modify: `frontend/src/not-found.tsx`
- Test: `frontend/src/settings/account/appearance-section.test.tsx` (add cases)
- Test: `frontend/src/not-found.test.tsx` (add case)
- Create: `docs/context/webapp-i18n.md` (repo-local context doc, per `/context-doc`)

**Interfaces:**
- Consumes: `LocaleProvider`, `useT`, `LOCALES`, `LOCALE_NAMES`, `isMember`.

- [ ] **Step 1: Write the failing tests**

Append to `frontend/src/settings/account/appearance-section.test.tsx` (inside the existing `describe`, after the second `it`; add imports at the top: `LocaleProvider` from `@/i18n/locale-provider`):

```tsx
	it("lists every locale by its own name and persists a pick", () => {
		window.localStorage.clear();
		render(
			<LocaleProvider loaders={{}}>
				<AppearanceSection />
			</LocaleProvider>,
		);
		const select = screen.getByRole("combobox", { name: /language/iu });
		expect(screen.getByRole("option", { name: "日本語" })).toBeInTheDocument();
		expect(screen.getByRole("option", { name: "English" })).toBeInTheDocument();
		fireEvent.change(select, { target: { value: "ja" } });
		expect(window.localStorage.getItem("engram:locale")).toBe("ja");
		expect(select).toHaveValue("ja");
	});
```

Append to `frontend/src/not-found.test.tsx` (inside the `describe`; add `LocaleProvider` import from `./i18n/locale-provider`):

```tsx
	it("renders the translated heading when a catalog is loaded", async () => {
		window.localStorage.setItem("engram:locale", "de");
		render(
			<LocaleProvider loaders={{ de: async () => ({ default: { "Page not found": "Seite nicht gefunden" } }) }}>
				<MemoryRouter>
					<NotFoundPage />
				</MemoryRouter>
			</LocaleProvider>,
		);
		expect(await screen.findByRole("heading", { name: "Seite nicht gefunden" })).toBeInTheDocument();
		window.localStorage.clear();
	});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/frontend && bunx vitest run src/settings/account/appearance-section.test.tsx src/not-found.test.tsx`
Expected: the two new cases FAIL (no combobox; heading stays English). Existing cases pass.

- [ ] **Step 3: Implement**

`frontend/src/main.tsx`: add `import { LocaleProvider } from "./i18n/locale-provider";` (keep imports sorted) and wrap the existing `<Suspense fallback={<LoadingScreen />}>…</Suspense>` that sits directly inside `<ThemeProvider>` with `<LocaleProvider>…</LocaleProvider>`. Nothing else in that tree moves.

`frontend/src/settings/account/appearance-section.tsx`, add imports and the language field after the theme `fieldset`:

```tsx
import { useT } from "@/i18n/locale-provider";
import { LOCALE_NAMES, LOCALES } from "@/i18n/locales";
import { isMember } from "@/lib/is-member";
import { cn } from "@/lib/utils";
import { fieldInput } from "@/lib/ui-classes";
```

```tsx
export function AppearanceSection() {
	const { theme, setTheme } = useTheme();
	const { t, locale, setLocale } = useT();
	return (
		<SettingsSectionCard title="Appearance" description="Choose how Engram looks on this device.">
			{/* existing theme <fieldset> unchanged */}
			<label className="mt-4 block text-sm">
				<span className="font-medium text-foreground">{t("Language")}</span>
				<select
					className={cn(fieldInput, "mt-1 block")}
					value={locale}
					onChange={(event) => {
						if (isMember(LOCALES, event.target.value)) {
							setLocale(event.target.value);
						}
					}}
				>
					{LOCALES.map((code) => (
						<option key={code} value={code}>
							{LOCALE_NAMES[code]}
						</option>
					))}
				</select>
			</label>
		</SettingsSectionCard>
	);
}
```

Only the new "Language" label uses `t()` here. The rest of this card is slice 2.

`frontend/src/not-found.tsx`: add `import { useT } from "./i18n/locale-provider";`, call `const { t } = useT();` at the top of `NotFoundPage`, and wrap the three strings:

```tsx
<h1 className={heading}>{t("Page not found")}</h1>
<p className="max-w-md text-muted-foreground text-sm">
	{t("We couldn't find what you're looking for. The link may be broken or the page may have moved.")}
</p>
<Button asChild className="mt-2">
	<Link to={ROUTES.HOME}>{t("Back to home")}</Link>
</Button>
```

`docs/context/webapp-i18n.md`: write the context doc (what exists, English-as-key model, why no `en` catalog, why no URL prefix, `useT()`-only rule, how to add a string, how `keys.test.ts` guards drift, what slices 2 to 4 still owe, the LLM-translation risk). Add its one-line trigger to the workspace `CLAUDE.md` Context Docs index in a separate workspace PR.

- [ ] **Step 4: Run the full gates**

```bash
cd backend/frontend
bunx vitest run
bun run check
bunx tsc --noEmit
```

Expected: all pass. Fix lint (import order) with `bunx biome check --write src/i18n src/main.tsx src/not-found.tsx src/settings`, then rerun the three gates. If `tsc` rejects `import.meta.glob` options, confirm `src/vite-env.d.ts` is included by `tsconfig.json`.

- [ ] **Step 5: Manual smoke and commit**

Run `make dev-selfhost` from the workspace (backend on `BACKEND_DIR=.worktrees/webapp-i18n` if needed). In Settings > Account: pick 日本語, reload, confirm the pick persisted and `<html lang="ja">`. Open `/nope`, confirm English still renders (catalogs are stubs).

```bash
git add frontend/src docs/context/webapp-i18n.md
git commit -m "feat(i18n): wire provider, language switcher and 404 proof surface"
```
