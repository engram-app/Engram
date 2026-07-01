import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { sentryVitePlugin } from "@sentry/vite-plugin";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import type { HtmlTagDescriptor, Plugin } from "vite";
import { defineConfig } from "vite";
import { bootstrapConfigFromEnv } from "./scripts/bootstrap-config";

/// <reference types="vitest" />

const apiTarget = process.env.VITE_API_TARGET ?? "http://localhost:4000";

// Saas-only bootstrap optimizations, gated on VITE_INLINE_BOOTSTRAP_CONFIG=1
// (set by `bun run build:saas`). The selfhost build leaves the flag unset, so
// this plugin is a no-op and the SSR-injected / fetched config path is wholly
// untouched. It does three things to cut time-to-login-modal:
//   1. preconnect + dns-prefetch to clerk.engram.page so the TLS handshake to
//      Clerk's FAPI happens DURING main-bundle parse, not after React mounts.
//   2. inline window.__ENGRAM_CONFIG__ so loadConfig() resolves synchronously
//      and the SPA never blocks first render on a /config.json round trip.
//   3. modulepreload the Clerk vendor + auth-provider + sign-in chunks so they
//      download in parallel with the main bundle instead of in a lazy waterfall.
function inlineBootstrap(): Plugin {
	const CLERK_CHUNKS = new Set(["clerk-auth-provider", "clerk-sign-in"]);
	return {
		name: "engram-inline-bootstrap",
		apply: "build",
		transformIndexHtml: {
			order: "post",
			handler(html, ctx) {
				if (process.env.VITE_INLINE_BOOTSTRAP_CONFIG !== "1") return;

				const { config, errors } = bootstrapConfigFromEnv(process.env);
				if (errors.length > 0) {
					throw new Error(`[inline-bootstrap] ${errors.join("; ")}`);
				}

				const tags: HtmlTagDescriptor[] = [
					{
						tag: "link",
						attrs: { rel: "preconnect", href: "https://clerk.engram.page", crossorigin: "" },
						injectTo: "head-prepend",
					},
					{
						tag: "link",
						attrs: { rel: "dns-prefetch", href: "https://clerk.engram.page" },
						injectTo: "head-prepend",
					},
					{
						tag: "script",
						children: `window.__ENGRAM_CONFIG__=${JSON.stringify(config)}`,
						injectTo: "head",
					},
				];

				for (const output of Object.values(ctx.bundle ?? {})) {
					if (output.type === "chunk" && CLERK_CHUNKS.has(output.name)) {
						tags.push({
							tag: "link",
							attrs: { rel: "modulepreload", href: `/${output.fileName}` },
							injectTo: "head",
						});
					}
				}

				return { html, tags };
			},
		},
	};
}

// Sentry source-map upload + release tagging. Active only when
// SENTRY_AUTH_TOKEN is present at build time (i.e. CI on the deploy
// workflow, never local dev). Plugin is a no-op otherwise — set
// `disable: true` so it doesn't try to upload empty assets.
const sentryAuthToken = process.env.SENTRY_AUTH_TOKEN;

// Source maps must NEVER ship to the public asset directory — they fully
// de-minify and expose application source. Sentry's plugin deletes them
// after upload, but ONLY when it is active; the Cloudflare Workers saas
// deploy builds with no SENTRY_AUTH_TOKEN, so the plugin self-disables and
// the maps would otherwise be served at app.engram.page. This fallback
// strips every leftover *.map from the build output whenever Sentry is not
// doing the upload (and therefore not deleting them itself).
function stripSourceMaps(outDir: string): Plugin {
	const deleteMaps = (dir: string) => {
		for (const entry of readdirSync(dir, { withFileTypes: true })) {
			const full = join(dir, entry.name);
			if (entry.isDirectory()) deleteMaps(full);
			else if (entry.name.endsWith(".map")) rmSync(full);
		}
	};

	return {
		name: "engram-strip-source-maps",
		apply: "build",
		closeBundle() {
			try {
				deleteMaps(outDir);
			} catch {
				// outDir may not exist (aborted build) — nothing to strip.
			}
		},
	};
}

const buildOutDir = fileURLToPath(new URL("../priv/static/app", import.meta.url));

export default defineConfig({
	test: {
		environment: "happy-dom",
		globals: true,
		setupFiles: ["./src/test-setup.ts"],
		exclude: ["**/node_modules/**", "**/dist/**", "**/e2e/**"],
	},
	// Tailwind v4 loads the typography plugin via `@plugin` in main.css —
	// the vite plugin's `plugins` option is ignored in this version.
	plugins: [
		react(),
		tailwindcss(),
		sentryVitePlugin({
			org: process.env.SENTRY_ORG ?? "engram-app",
			project: process.env.SENTRY_PROJECT ?? "engram-frontend",
			authToken: sentryAuthToken,
			disable: !sentryAuthToken,
			release: { name: process.env.VITE_GIT_SHA },
			// When Sentry IS uploading, have it delete the maps it just uploaded.
			sourcemaps: { filesToDeleteAfterUpload: ["**/*.map"] },
			// A Sentry API blip must NOT fail the production image build (it broke a
			// deploy on 2026-06-24). errorHandler downgrades upload/release failures
			// to a warning so the build — and the deploy — proceeds. The app ships
			// fine without sourcemaps; only Sentry stack-trace readability degrades.
			errorHandler: (err) => {
				console.warn(
					"[sentry-vite-plugin] non-fatal: sourcemap/release step failed, continuing build:",
					err?.message ?? err,
				);
			},
		}),
		// Backstop for builds where Sentry is disabled (no auth token).
		stripSourceMaps(buildOutDir),
		// Saas-only: inline config + preconnect + clerk modulepreload (no-op
		// unless VITE_INLINE_BOOTSTRAP_CONFIG=1).
		inlineBootstrap(),
	],
	resolve: {
		alias: {
			"@": fileURLToPath(new URL("./src", import.meta.url)),
		},
	},
	base: "/",
	build: {
		outDir: "../priv/static/app",
		emptyOutDir: true,
		// 'hidden' generates maps (so Sentry can de-minify stack traces) but omits
		// the //# sourceMappingURL comment, so browsers never auto-fetch them.
		// The maps themselves are removed from served output after build by the
		// Sentry plugin (on upload) or the stripSourceMaps backstop (otherwise).
		sourcemap: "hidden",
	},
	server: {
		port: 5173,
		proxy: {
			// changeOrigin rewrites the Host header to the target — required when
			// VITE_API_TARGET points at a remote host routed by Host (e.g. Cloudflare);
			// harmless against localhost.
			"/api": {
				target: apiTarget,
				changeOrigin: true,
			},
			// OAuth API endpoints — Phoenix-served JSON. /oauth/consent is a SPA
			// route (React renders consent UI) so we DON'T proxy that one.
			"/oauth/register": { target: apiTarget, changeOrigin: true },
			"/oauth/token": { target: apiTarget, changeOrigin: true },
			"/oauth/revoke": { target: apiTarget, changeOrigin: true },
			"/oauth/authorize": { target: apiTarget, changeOrigin: true },
			"/.well-known": {
				target: apiTarget,
				changeOrigin: true,
			},
			"/socket": {
				target: apiTarget,
				changeOrigin: true,
				ws: true,
			},
		},
	},
});
