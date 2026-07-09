import { defineConfig, devices } from "@playwright/test";

const isCI = Boolean(process.env.CI);

// Ports — configurable via env for parallel CI, defaults for local dev
const LOCAL_BACKEND_PORT = Number(process.env.PW_LOCAL_BACKEND_PORT ?? 4000);
const LOCAL_VITE_PORT = Number(process.env.PW_LOCAL_VITE_PORT ?? 5173);
const CLERK_BACKEND_PORT = Number(process.env.PW_CLERK_BACKEND_PORT ?? 4001);
const CLERK_VITE_PORT = Number(process.env.PW_CLERK_VITE_PORT ?? 5174);

// Clerk webServers are only started when Clerk credentials are available.
const clerkPublishableKey = process.env.VITE_CLERK_PUBLISHABLE_KEY ?? "";
const hasClerkCreds = clerkPublishableKey.length > 0;

export default defineConfig({
	testDir: "./e2e",
	timeout: 30_000,
	expect: { timeout: 10_000 },
	fullyParallel: false,
	forbidOnly: isCI,
	retries: isCI ? 1 : 0,
	reporter: isCI ? "github" : "html",
	globalSetup: "./e2e/global-setup.ts",
	globalTeardown: "./e2e/global-teardown.ts",
	use: {
		trace: "on-first-retry",
		screenshot: "only-on-failure",
		...devices["Desktop Chrome"],
	},

	projects: [
		{
			name: "local",
			testMatch:
				/\/(?:local-auth|dark-mode|mobile|note-live-update|note-properties|tree-ops-sync)\.spec\.ts$/u,
			use: {
				baseURL: `http://localhost:${LOCAL_VITE_PORT}`,
			},
		},
		{
			name: "clerk",
			testMatch: /\/(?:clerk-auth|onboarding-ftux)\.spec\.ts$/u,
			use: {
				baseURL: `http://localhost:${CLERK_VITE_PORT}`,
			},
		},
	],

	webServer: [
		{
			command: "mix phx.server",
			cwd: "..",
			// /api/health is a bare liveness check (always 200 once the Endpoint
			// boots) — it doesn't prove Postgres is attached, so it can pass
			// before the app can actually serve a real request. /health/deep
			// round-trips Ecto.Repo, which is the earliest point the backend is
			// genuinely usable (#964 — boot-race false-ready flake).
			url: `http://localhost:${LOCAL_BACKEND_PORT}/api/health/deep`,
			timeout: 120_000,
			reuseExistingServer: !isCI,
			stdout: "pipe",
			stderr: "pipe",
			env: {
				MIX_ENV: "dev",
				AUTH_PROVIDER: "local",
				PHX_SERVER: "true",
				PORT: String(LOCAL_BACKEND_PORT),
				// Local dev/e2e only — 32-byte base64 key, not used in production.
				KEY_PROVIDER: process.env.KEY_PROVIDER ?? "local",
				ENCRYPTION_MASTER_KEY:
					process.env.ENCRYPTION_MASTER_KEY ?? "uB2okhpf1lb6quoXIk+ZVIQDenCUnGnZuTb8IA/iZ4w=",
			},
		},
		{
			command: `bun run dev -- --port ${LOCAL_VITE_PORT}`,
			cwd: ".",
			// A bare `port:` check only proves Vite accepted a TCP connection —
			// not that its /api proxy can actually reach Phoenix (#964). Poll
			// through the proxy so this only goes green once the whole chain
			// (Vite -> proxy -> Phoenix -> Postgres) is really up.
			url: `http://localhost:${LOCAL_VITE_PORT}/api/health/deep`,
			// Must cover Phoenix's boot budget too: this URL proxies to Phoenix,
			// so a 15s cap would fail Vite while Phoenix is still legitimately booting.
			timeout: 120_000,
			reuseExistingServer: !isCI,
			env: {
				VITE_AUTH_PROVIDER: "local",
				VITE_API_TARGET: `http://localhost:${LOCAL_BACKEND_PORT}`,
			},
		},
		// Clerk servers are only started when credentials are present (CI or explicit local dev).
		...(hasClerkCreds
			? [
					{
						command: "mix phx.server",
						cwd: "..",
						// See the "local" project's Phoenix webServer entry above (#964).
						url: `http://localhost:${CLERK_BACKEND_PORT}/api/health/deep`,
						timeout: 120_000,
						reuseExistingServer: !isCI,
						stdout: "pipe" as const,
						stderr: "pipe" as const,
						env: {
							MIX_ENV: "dev",
							AUTH_PROVIDER: "clerk",
							PHX_SERVER: "true",
							PORT: String(CLERK_BACKEND_PORT),
							KEY_PROVIDER: process.env.KEY_PROVIDER ?? "local",
							ENCRYPTION_MASTER_KEY:
								process.env.ENCRYPTION_MASTER_KEY ?? "uB2okhpf1lb6quoXIk+ZVIQDenCUnGnZuTb8IA/iZ4w=",
							CLERK_JWKS_URL: process.env.CLERK_JWKS_URL ?? "",
							CLERK_ISSUER: process.env.CLERK_ISSUER ?? "",
							CLERK_PUBLISHABLE_KEY: clerkPublishableKey,
						},
					},
					{
						command: `bun run dev -- --port ${CLERK_VITE_PORT}`,
						cwd: ".",
						// See the "local" project's Vite webServer entry above (#964).
						url: `http://localhost:${CLERK_VITE_PORT}/api/health/deep`,
						// Same Phoenix-boot budget as the local Vite entry above.
						timeout: 120_000,
						reuseExistingServer: !isCI,
						env: {
							VITE_AUTH_PROVIDER: "clerk",
							VITE_CLERK_PUBLISHABLE_KEY: clerkPublishableKey,
							VITE_API_TARGET: `http://localhost:${CLERK_BACKEND_PORT}`,
						},
					},
				]
			: []),
	],
});
