import { setupClerkTestingToken } from "@clerk/testing/playwright";
import type { OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type {
	OAuthClientInformationMixed,
	OAuthClientMetadata,
	OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";
import { expect, type Page, test } from "@playwright/test";
import {
	API_URL,
	APP_URL,
	clerkSignIn,
	createUnonboardedUser,
	deleteClerkUser,
	loadAuthState,
} from "./clerk-helpers";

/**
 * The MCP-first path, end to end, the way a real connector walks it.
 *
 * A brand-new user's first contact is an AI app: it discovers our OAuth server
 * from the MCP endpoint's 401, registers itself (DCR), sends the user to
 * /oauth/authorize, and waits for the code. The user signs in, finishes
 * onboarding, approves, and the app then reads and writes notes. Finally the
 * note the app wrote is visible in the web app.
 *
 * The client is the official MCP TypeScript SDK, which is what Claude Code and
 * most connectors are built on. Its discovery, resource-indicator check, DCR
 * and PKCE are the real thing, so a drift in our metadata or token endpoint
 * fails here the way it fails for users (ChatGPT's CIMD and Claude's
 * `invalid_client` both reached prod past hand-rolled tests).
 *
 * Phoenix and the SPA run on different origins here (ENGRAM_FRONTEND_URL in
 * playwright.config.ts), the same split as saas api./app.engram.page.
 */

const MCP_URL = new URL("/api/mcp", API_URL);

// Loopback on the SPA's own origin, so approving cannot navigate off-box. The
// page 404s; the code is read from the URL.
const CALLBACK_PATH = "/oauth-callback-test";
const REDIRECT_URI = `${APP_URL}${CALLBACK_PATH}`;

const NOTE_PATH = "Hello from my AI.md";
const NOTE_BODY = "Written by an MCP client on its first connection.";

/** Holds what a connector would persist between launches. */
class MemoryProvider implements OAuthClientProvider {
	authorizationUrl: URL | null = null;
	private info?: OAuthClientInformationMixed;
	private saved?: OAuthTokens;
	private verifier = "";

	get redirectUrl(): string {
		return REDIRECT_URI;
	}

	get clientMetadata(): OAuthClientMetadata {
		return {
			// Resolves to the `claude_code` catalog slug, which lets the wizard
			// skip its tool question (LogoAllowlist client_name fallback).
			client_name: "Claude Code",
			redirect_uris: [REDIRECT_URI],
			grant_types: ["authorization_code", "refresh_token"],
			response_types: ["code"],
			token_endpoint_auth_method: "none",
		};
	}

	clientInformation(): OAuthClientInformationMixed | undefined {
		return this.info;
	}

	saveClientInformation(info: OAuthClientInformationMixed): void {
		this.info = info;
	}

	tokens(): OAuthTokens | undefined {
		return this.saved;
	}

	saveTokens(tokens: OAuthTokens): void {
		this.saved = tokens;
	}

	redirectToAuthorization(url: URL): void {
		this.authorizationUrl = url;
	}

	saveCodeVerifier(verifier: string): void {
		this.verifier = verifier;
	}

	codeVerifier(): string {
		return this.verifier;
	}
}

test.describe("MCP-first: a new user connects an AI app", () => {
	const skip = loadAuthState().skipped || !process.env.E2E_CLERK_SECRET_KEY;
	let pending: { email: string; id: string } | null = null;

	test.skip(() => skip, "E2E_CLERK_SECRET_KEY not set — Clerk browser tests skipped");

	test.beforeEach(async ({ page }) => {
		// Per attempt: the journey consumes the user's un-onboarded state.
		pending = await createUnonboardedUser("e2e-browser-mcpfirst");
		await setupClerkTestingToken({ page });
	});

	test.afterEach(async () => {
		if (pending) {
			await deleteClerkUser(pending.id);
			pending = null;
		}
	});

	test("discover, sign up, approve, then read and write notes", {
		tag: ["@canary"],
		annotation: [
			{ type: "cadence", description: "hourly" },
			{ type: "targets", description: "ci,staging" },
		],
	}, async ({ page }) => {
		const provider = new MemoryProvider();

		// 1. First contact: the unauthenticated connect must end in a redirect
		//    to our authorization endpoint, reached by discovery alone.
		await test.step("discover-and-register", async () => {
			await expect(connect(provider)).rejects.toThrow(/unauthorized/iu);
			expect(provider.authorizationUrl, "SDK never reached redirectToAuthorization").not.toBeNull();
			expect(provider.clientInformation()?.client_id, "DCR returned no client_id").toBeTruthy();
		});
		const authorize = provider.authorizationUrl as URL;

		// 2. The user: sign in, onboard, approve.
		const code = await test.step("sign-in-onboard-approve", () =>
			approveAsNewUser(page, (pending as { email: string }).email, authorize));

		// 3. The app finishes the exchange and works.
		await test.step("token-exchange-and-tools", async () => {
			await new StreamableHTTPClientTransport(MCP_URL, { authProvider: provider }).finishAuth(code);
			const client = await connect(provider);
			try {
				const { tools } = await client.listTools();
				const names = tools.map((t) => t.name);
				expect(names).toEqual(expect.arrayContaining(["write_note", "get_notes", "search_notes"]));

				const wrote = await client.callTool({
					name: "write_note",
					arguments: { path: NOTE_PATH, content: NOTE_BODY },
				});
				expect(wrote.isError, JSON.stringify(wrote.content)).toBeFalsy();

				const read = await client.callTool({
					name: "get_notes",
					arguments: { paths: [NOTE_PATH] },
				});
				expect(read.isError, JSON.stringify(read.content)).toBeFalsy();
				expect(JSON.stringify(read.content)).toContain(NOTE_BODY);
			} finally {
				await client.close();
			}
		});

		// 4. What the app wrote is in the user's vault in the web app.
		await test.step("note-visible-in-web", async () => {
			await page.goto(`${APP_URL}/`);
			await expect(page.getByText("Hello from my AI").first()).toBeVisible({ timeout: 20_000 });
		});
	});
});

async function connect(provider: MemoryProvider): Promise<Client> {
	const client = new Client({ name: "engram-e2e", version: "1.0.0" });
	await client.connect(new StreamableHTTPClientTransport(MCP_URL, { authProvider: provider }));
	return client;
}

/** Sign in mid-authorization, finish onboarding, approve; returns the code. */
async function approveAsNewUser(page: Page, email: string, authorize: URL): Promise<string> {
	await clerkSignIn(page, email, authorize.toString());

	// /oauth/authorize 302s to the SPA's consent page, which bounces an
	// un-onboarded user into the wizard. A connector signup's only step is
	// the terms (SaaS); with billing off there is none.
	await page.waitForURL(/\/(?:onboard|oauth\/consent)/u, { timeout: 25_000 });
	if (new URL(page.url()).pathname === "/onboard/agreement") {
		await page.getByLabel(/I have read and agree/iu).click();
		await page.getByRole("button", { name: /^continue$/iu }).click();
	}

	await page.waitForURL(/\/oauth\/consent/u, { timeout: 25_000 });
	await page.getByRole("button", { name: /^approve$/iu }).click();
	await page.waitForURL((url) => new URL(url).pathname === CALLBACK_PATH, { timeout: 25_000 });

	const callback = new URL(page.url());
	expect(callback.searchParams.get("error")).toBeNull();
	expect(callback.searchParams.get("state")).toBe(authorize.searchParams.get("state"));
	const code = callback.searchParams.get("code");
	expect(code).toBeTruthy();
	return code as string;
}
