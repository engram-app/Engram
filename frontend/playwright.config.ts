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
			testMatch: /\/(local-auth|dark-mode|mobile|note-live-update|note-properties)\.spec\.ts$/u,
			use: {
				baseURL: `http://localhost:${LOCAL_VITE_PORT}`,
			},
		},
		{
			name: "clerk",
			testMatch: /\/(clerk-auth|onboarding-ftux)\.spec\.ts$/u,
			use: {
				baseURL: `http://localhost:${CLERK_VITE_PORT}`,
			},
		},
	],

	webServer: [
		{
			command: "mix phx.server",
			cwd: "..",
			url: `http://localhost:${LOCAL_BACKEND_PORT}/api/health`,
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
			port: LOCAL_VITE_PORT,
			timeout: 15_000,
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
						url: `http://localhost:${CLERK_BACKEND_PORT}/api/health`,
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
						port: CLERK_VITE_PORT,
						timeout: 15_000,
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
