import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate, useSearchParams } from "react-router";
import { grantWithin, isReadOnlyScope } from "@/components/access-level-select";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { useVaultAccess } from "@/components/vault-access-fields";
import { VaultAccessFlow } from "@/components/vault-access-flow";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import { serverErrorMessage } from "@/lib/server-error";
import { destructiveAlert, heading } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { MCP_CLIENTS } from "../analytics/events";
import { track } from "../analytics/track";
import { api } from "../api/client";
import { fetchOAuthClient, type OAuthConsentParams, postOAuthConsent } from "../api/oauth";
import {
	type Connection,
	useAccessLevelsSupported,
	useConnections,
	useMe,
	useOnboardingStatus,
	useSetOnboardingProfile,
	useVaults,
} from "../api/queries";
import { connectionId as oauthConnectionId } from "../billing/existing-connections-panel";
import { useConnectionCap } from "../billing/use-connection-cap";
import AuthPanel from "../layout/auth-panel";
import AuthShell from "../layout/auth-shell";
import { isMember } from "../lib/is-member";
import { ROUTES } from "../routes";
import { settingsHash, settingsTo } from "../settings/settings-hash";
import { clearPendingAuthorization, stashPendingAuthorization } from "./pending-authorization";

// The tab an approval opens while the client finishes connecting: the app
// root, which lands on the active vault.
const VAULT_URL = ROUTES.HOME;

const REQUIRED_PARAMS = [
	"client_id",
	"redirect_uri",
	"response_type",
	"code_challenge",
	"code_challenge_method",
] as const;

// `scope` is OPTIONAL in an authorization request (RFC 6749 §4.1.1) and the
// backend already defaults an absent scope to "mcp" (Engram.OAuth.
// validate_authorization_request). Requiring it here rejected legal
// scope-less requests — Claude Code's MCP (re)connect flow omits it — with a
// dead-end "Invalid authorization request" page. Mirror the backend default.
const DEFAULT_SCOPE = "mcp";

type RequiredParam = (typeof REQUIRED_PARAMS)[number];

function readParams(search: URLSearchParams): {
	values: Record<RequiredParam, string> & { scope: string; state: string };
	resource: string | null;
	iss: string | null;
	missing: RequiredParam[];
} {
	const values: Record<RequiredParam, string> & { scope: string; state: string } = {
		client_id: "",
		redirect_uri: "",
		response_type: "",
		code_challenge: "",
		code_challenge_method: "",
		state: "",
		scope: "",
	};
	const missing: RequiredParam[] = [];

	for (const key of REQUIRED_PARAMS) {
		const v = search.get(key);
		if (v) {
			values[key] = v;
		} else {
			missing.push(key);
		}
	}
	values.scope = search.get("scope") || DEFAULT_SCOPE;
	// RECOMMENDED, not required (RFC 6749 §4.1.1): absent stays "" and is
	// dropped from both the consent body and the Cancel redirect.
	values.state = search.get("state") || "";

	return { values, resource: search.get("resource"), iss: search.get("iss"), missing };
}

// The client's catalog slug is already resolved server-side from the redirect
// it's using (see OAuthClientMetadata.slug) — never the raw client_name or
// host, both of which are attacker/client-supplied free text. Any slug this
// analytics enum doesn't enumerate (e.g. "claude_code", "antigravity",
// "cline" — real catalog slugs, just not one of the three this event
// distinguishes) becomes "other", same as no slug at all.
function toMcpClient(slug: string | null | undefined): (typeof MCP_CLIENTS)[number] {
	return isMember(MCP_CLIENTS, slug) ? slug : "other";
}

// RFC 9207 §2: error responses carry `iss` too, when the server sent one.
function buildCancelUrl(redirectUri: string, state: string, iss: string | null): string {
	const answer = new URLSearchParams({ error: "access_denied" });
	if (state) {
		answer.set("state", state);
	}
	if (iss) {
		answer.set("iss", iss);
	}
	return `${redirectUri}${redirectUri.includes("?") ? "&" : "?"}${answer.toString()}`;
}

export default function OAuthAuthorizePage() {
	const { t } = useT();
	const [searchParams] = useSearchParams();
	const { values, resource, iss, missing } = readParams(searchParams);

	const clientQuery = useQuery({
		// The redirect is part of the key: it is what the backend resolves the
		// client's catalog slug from, so two requests for the same client with
		// different redirects are not the same answer.
		queryKey: ["oauth-client", values.client_id, values.redirect_uri],
		queryFn: () => fetchOAuthClient(values.client_id, values.redirect_uri),
		enabled: missing.length === 0 && Boolean(values.client_id),
		retry: false,
	});

	const meQuery = useMe();
	const vaultsQuery = useVaults();
	const levelsSupported = useAccessLevelsSupported();
	const navigate = useNavigate();
	const location = useLocation();
	const qc = useQueryClient();

	const onboardingQuery = useOnboardingStatus();
	const setProfile = useSetOnboardingProfile();
	const onboarding = onboardingQuery.data;
	// Signing up happens INSIDE this flow, so a user can reach this screen with
	// no terms accepted, no plan and no vault. Approving in that state mints a
	// grant the vault gate then refuses on every single call — the dead end
	// #1666 is about. Send them through the wizard first, then resume.
	//
	// This page sits OUTSIDE OnboardingGate deliberately (router.tsx) and must
	// stay there: the gate redirects to `/onboard/<step>` and would drop the
	// authorization request on the floor. Bouncing here is what lets the
	// request survive the detour.
	// `gate_ok`, NOT `next_step === "done"`. The backend decouples the two on
	// purpose: an obsidian-path user is admitted by the gate while the wizard
	// parks them on `"vault"` until the plugin first-syncs. Gating on
	// `next_step` bounced exactly those users consent → wizard → consent
	// forever, since the wizard had nothing left to collect and the gate had
	// nothing left to refuse.
	const needsOnboarding = Boolean(onboarding && !onboarding.gate_ok);
	// Cancel redirects to `redirect_uri` straight from this page's query string,
	// and nothing upstream has to have validated it: anyone can link here. So a
	// redirect the client never registered gets no consent card at all, and with
	// it no Cancel, which would otherwise be an open redirect (RFC 9700 §4.11).
	const redirectRefused = clientQuery.data?.redirect_uri_registered === false;
	// Cancel fails closed: only a redirect the backend confirmed gets one. A
	// backend too old to answer still allows Approve, which it re-validates.
	const redirectVerified = clientQuery.data?.redirect_uri_registered === true;
	const bounced = useRef(false);

	useEffect(() => {
		if (!needsOnboarding || bounced.current || missing.length > 0) {
			return;
		}
		// WAIT for the client lookup to settle. The slug rides on that response,
		// and this effect runs on the first render, when it is still undefined —
		// bouncing here would park a null slug and the ref guard below would stop
		// it ever being reconsidered, so the tool question would be asked of
		// every MCP-first user despite us knowing the answer. An errored lookup
		// renders "Unknown OAuth client" and must not bounce at all.
		if (clientQuery.isLoading || clientQuery.isError || redirectRefused) {
			return;
		}
		bounced.current = true;

		const slug = clientQuery.data?.slug ?? null;
		// The boolean is deliberately not surfaced. The copy below promises no
		// automatic return, so a failed stash needs no distinct rendering, and
		// `onboardingDoneTarget()` already falls back to "/" when nothing was
		// parked. Reading it into state here would also mean an effect that
		// synchronously sets state, which the render-compiler lint rejects.
		stashPendingAuthorization(location.search);

		// Connecting a tool IS the answer to "which tools do you use", so the
		// questionnaire is pre-answered instead of asked. An unattributable
		// client, or a write that fails, just means the user sees the step —
		// the pre-existing behaviour, not a new failure.
		const preAnswerTools = async () => {
			if (slug && !onboarding?.profile?.tools?.length) {
				try {
					// `tools_prefilled` marks this as answered BEFORE the wizard,
					// which is what drops the tools step from the chain. Without
					// it the backend cannot tell this apart from a user answering
					// the question themselves.
					await setProfile.mutateAsync({ tools: [slug], tools_prefilled: true });
				} catch (err) {
					// Swallowed HERE, not left to the caller: `finally` re-throws,
					// so a rejection would surface as an unhandled rejection. The
					// wizard simply asks the question instead.
					//
					// Logged rather than silent: this POST is a cross-file
					// vocabulary contract (a `LogoAllowlist` slug must exist in
					// `Onboarding.valid_tools/0`). If those drift, the 422 lands
					// here and the ONLY other symptom is one vendor's users
					// seeing a tools step they should not.
					console.warn("onboarding tool pre-answer failed", slug, err);
				}
			}
		};

		// `finally`, so the handoff happens whether or not the pre-answer lands.
		// Stranding someone on a consent screen they cannot use because an
		// optional convenience failed would be a worse bug than the one this
		// whole change exists to fix.
		preAnswerTools().finally(() => navigate("/onboard", { replace: true }));
	}, [
		needsOnboarding,
		missing.length,
		clientQuery.data,
		clientQuery.isLoading,
		clientQuery.isError,
		redirectRefused,
		location.search,
		navigate,
		onboarding,
		setProfile,
	]);

	// Nothing left to resume once they are through. A stash that outlives its
	// flow would divert a later, unrelated trip through the wizard.
	//
	// Not on the visit that parked it: on self-host the connector pre-answer
	// alone satisfies the gate, so the refetch says gate_ok before the handoff
	// to /onboard, and clearing then strands the user on the dashboard.
	useEffect(() => {
		if (onboarding?.gate_ok && !bounced.current) {
			clearPendingAuthorization();
		}
	}, [onboarding]);

	// Proactive cap check — kind comes from the OAuth client metadata so we
	// pick the right cap key (mcp vs obsidian). Default to "mcp" until the
	// client query resolves; this only matters for the loading transition,
	// since the cap panel is gated on `!isLoadingShell` too.
	const clientKind: "mcp" | "obsidian" = clientQuery.data?.kind ?? "mcp";
	// Read only and per-vault levels (#174): MCP clients only (an Obsidian
	// device must write), and only when the backend advertises them. One that
	// predates them would ignore the fields and mint full access.
	const leveled = clientKind === "mcp" && levelsSupported;
	const capCheck = useConnectionCap(clientKind);
	// Only need the existing-connection details when at cap (for the heads-up
	// banner + the implicit disconnect on Approve).
	const connections = useConnections({ enabled: capCheck.atCap });
	const existingPeer = (connections.data ?? []).find((c): c is Connection => c.kind === clientKind);

	// "All vaults" (`selected === null`) stays all-vaults as new ones are
	// created. Choosing per vault is exactly the vaults not at No access, even
	// when that is every one of them: these are different grants. Vaults that
	// left the fetched list drop out because the set is built from it.
	const access = useVaultAccess();
	const live = vaultsQuery.data;
	const selected = access.perVault
		? new Set((live ?? []).map((v) => String(v.id)).filter((id) => access.levelOf(id) !== "none"))
		: null;
	// The backend refuses a grant that reaches no vault, so it is never offered.
	const reachesNothing = !access.reaches((live ?? []).map((v) => String(v.id)));

	// Prefilled via `placeholder`, never `value`: an untouched default is not a
	// choice, and only a non-empty typed value is sent.
	const [label, setLabel] = useState("");
	// A client that asked for read-only keeps it: the table offers no Write.
	// A pick with no Write anywhere asks for `mcp:read` too, so the AI is
	// offered no write tools.
	const clientAskedReadOnly = isReadOnlyScope(values.scope);
	const readOnly = clientAskedReadOnly || !access.writes((live ?? []).map((v) => String(v.id)));
	const maxLevel = readOnly ? "read" : "write";
	// Back from the review step lands on the title.
	const titleRef = useRef<HTMLHeadingElement>(null);
	const [submitError, setSubmitError] = useState<string | null>(null);
	const [submitting, setSubmitting] = useState(false);
	// At-cap users get a confirm modal before the implicit swap so they see
	// EXACTLY what's about to be disconnected, not just an inline banner.
	const [showSwapConfirm, setShowSwapConfirm] = useState(false);

	if (missing.length > 0) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>{t("Invalid authorization request")}</h1>
					<div role="alert" className={destructiveAlert}>
						<p className="font-medium text-foreground">{t("Missing required OAuth parameters:")}</p>
						<ul className="mt-2 list-inside list-disc text-muted-foreground">
							{missing.map((m) => (
								<li key={m}>
									<code>{m}</code>
								</li>
							))}
						</ul>
					</div>
					<p className="text-muted-foreground text-sm">
						{t("This page should be opened via an OAuth client redirect, not directly.")}
					</p>
				</AuthPanel>
			</AuthShell>
		);
	}

	if (clientQuery.isError) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>{t("Unknown OAuth client")}</h1>
					<div role="alert" className={destructiveAlert}>
						<p className="text-muted-foreground">
							{t("The client requesting access is not registered with Engram.")}
						</p>
					</div>
				</AuthPanel>
			</AuthShell>
		);
	}

	if (redirectRefused) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>{t("Invalid authorization request")}</h1>
					<div role="alert" className={destructiveAlert}>
						<p className="text-muted-foreground">
							{t("This app did not register the address it asked to send you back to.")}
						</p>
					</div>
				</AuthPanel>
			</AuthShell>
		);
	}

	// Held while the effect above stashes the request and hands off to the
	// wizard. Rendering the consent card here would offer an Approve button
	// that mints a grant nothing can use.
	if (needsOnboarding) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>{t("Finish setting up Engram")}</h1>
					{/* States the PURPOSE without promising an automatic return.
					    The stash is a no-op when storage is disabled or full, and
					    the previous copy ("you'll come straight back here")
					    guaranteed a comeback that then quietly ended on the
					    dashboard with the waiting client never mentioned again.
					    The wizard shows no banner (it cluttered every step); the
					    consent screen it returns to names the client. */}
					<p className="text-muted-foreground text-sm">
						<Trans
							text="Taking you to setup so you can finish connecting {app}."
							slots={{
								app: (
									<span className="text-primary-ink">
										{clientQuery.data?.client_name ?? t("this app")}
									</span>
								),
							}}
						/>
					</p>
				</AuthPanel>
			</AuthShell>
		);
	}

	const handleApprove = async () => {
		// At cap with a known peer: open the confirm modal first so the user
		// sees the exact disconnect that's about to happen. Confirm there runs
		// the actual swap via `runSubmit(true)`.
		if (capCheck.atCap && existingPeer) {
			setShowSwapConfirm(true);
			return;
		}
		await runSubmit(false);
	};

	const runSubmit = async (isSwap: boolean) => {
		setSubmitting(true);
		setSubmitError(null);
		// Every approval opens the vault, so the user lands in it while the
		// client finishes connecting. Before any await: a popup blocker refuses
		// a tab opened outside the click.
		const vaultTab = window.open(VAULT_URL, "_blank");

		// Obsidian's device-code flow is a different surface (device-link-page.tsx,
		// plugin_connect_*) — this event name says "mcp" and must mean it.
		const isMcp = clientKind === "mcp";
		const mcpClient = toMcpClient(clientQuery.data?.slug);
		if (isMcp) {
			track("mcp_connect_attempted", { client: mcpClient });
		}

		const body: OAuthConsentParams = {
			client_id: values.client_id,
			redirect_uri: values.redirect_uri,
			response_type: values.response_type,
			code_challenge: values.code_challenge,
			code_challenge_method: values.code_challenge_method,
			scope: values.scope,
		};
		if (values.state) {
			body.state = values.state;
		}
		if (resource) {
			body.resource = resource;
		}
		if (iss) {
			body.iss = iss;
		}
		if (selected && selected.size > 0) {
			body.vault_ids = [...selected];
		}
		const trimmed = label.trim();
		if (trimmed) {
			body.label = trimmed;
		}
		if (leveled && readOnly) {
			body.read_only = true;
		}
		if (leveled) {
			// Every "none" entry rides in the access token, so the request spells
			// one out only where the policy would otherwise reach that vault.
			Object.assign(
				body,
				access.request(
					(live ?? []).map((v) => String(v.id)),
					maxLevel,
				),
			);
		}

		// If swapping, disconnect the existing connection of the same kind
		// first so the consent call doesn't 402. Mirrors the /link page swap
		// shape — the confirm modal already named what's about to disconnect.
		let swappedFromName: string | null = null;
		try {
			if (isSwap && existingPeer) {
				const existingId = oauthConnectionId(existingPeer);
				if (existingId) {
					swappedFromName = existingPeer.name ?? t("previous connection");
					const path =
						existingPeer.kind === "obsidian"
							? `/connections/device/${existingId}`
							: `/connections/oauth/${existingId}`;
					await api.del(path);
					await qc.invalidateQueries({ queryKey: ["connections"] });
					await qc.invalidateQueries({ queryKey: ["billing", "status"] });
				}
			}

			const { redirect_uri, granted } = await postOAuthConsent(body);
			// The backend echoes what it stored. A code with no echo, or one
			// wider than the pick, is not the grant the user approved: it never
			// reaches the client. (A refusal redirect carries no code.)
			const grantsCode = new URL(redirect_uri).searchParams.has("code");
			const asked = body.vault_access || body.default_access;
			if (
				asked &&
				grantsCode &&
				!(
					grantWithin(
						granted,
						body,
						(live ?? []).map((v) => String(v.id)),
					) &&
					(!body.read_only || isReadOnlyScope(granted?.scope ?? ""))
				)
			) {
				setSubmitError(
					t(
						"The server granted more access than you chose, so nothing was connected. Try again, or contact support if this keeps happening.",
					),
				);
				track("mcp_connect_failed", { client: mcpClient, reason: "unknown" });
				vaultTab?.close();
				setSubmitting(false);
				return;
			}
			if (isMcp) {
				track("mcp_connect_succeeded", { client: mcpClient });
			}
			// A 200 can still carry a refusal (`?error=`): nothing will connect.
			if (!grantsCode) {
				vaultTab?.close();
			} else if (vaultTab === null) {
				// Blocked (every in-app/auth webview does): the client comes first.
				track(
					"vault_tab_blocked",
					isMcp ? { client_kind: "mcp", client: mcpClient } : { client_kind: "obsidian" },
				);
			}
			window.location.assign(redirect_uri);
		} catch (e: unknown) {
			vaultTab?.close();
			if (swappedFromName) {
				// Disconnect succeeded but consent did not — user is now at 0
				// connections instead of 1. Make that visible.
				setSubmitError(
					t(
						"Disconnected '{name}' but authorizing the new connection failed. Re-run the request from {client} — no connections of this kind are currently active.",
						{ name: swappedFromName, client: clientName },
					),
				);
				if (isMcp) {
					track("mcp_connect_failed", { client: mcpClient, reason: "unknown" });
				}
				setSubmitting(false);
				return;
			}
			// LimitExceededError fallback is no longer expected on the at-cap path
			// (we pre-disconnected). Keep the guard for the rare race where the
			// cap re-trips between disconnect + consent.
			if (e instanceof Error && e.name === "LimitExceededError") {
				if (isMcp) {
					track("mcp_connect_failed", { client: mcpClient, reason: "limit_exceeded" });
				}
				setSubmitting(false);
				return;
			}
			setSubmitError(serverErrorMessage(e, t("Authorization failed"), t));
			if (isMcp) {
				track("mcp_connect_failed", { client: mcpClient, reason: "unknown" });
			}
			setSubmitting(false);
		}
	};

	const handleCancel = () => {
		track("mcp_connect_denied", { client: toMcpClient(clientQuery.data?.slug) });
		window.location.assign(buildCancelUrl(values.redirect_uri, values.state, iss));
	};

	const clientName = clientQuery.data?.client_name ?? t("this app");
	const isLoadingShell =
		clientQuery.isLoading ||
		vaultsQuery.isLoading ||
		meQuery.isLoading ||
		onboardingQuery.isLoading;

	return (
		<AuthShell>
			<AuthPanel scroll={false} className="gap-4 overflow-y-auto">
				<header className="flex flex-col gap-1">
					<h1 ref={titleRef} tabIndex={-1} className={cn(heading, "outline-none")}>
						<Trans
							text="Authorize {client}"
							slots={{ client: <span className="text-primary-ink">{clientName}</span> }}
						/>
					</h1>
					<p className="text-muted-foreground text-sm">
						{t("This app is requesting access to your Engram.")}
					</p>
					{meQuery.data ? (
						// Own line, one line: a long address wrapped mid-sentence.
						<p className="truncate text-muted-foreground text-sm" title={meQuery.data.email}>
							{t("Signed in as {email}.", { email: meQuery.data.email })}
						</p>
					) : null}
					{/* Provenance is anti-phishing (the name is self-asserted, the
					    hosts are not), but when both hosts match the return line
					    already says it. */}
					{clientQuery.data?.client_host &&
					clientQuery.data.client_host !== clientQuery.data.redirect_host ? (
						<p className="text-muted-foreground text-sm">
							{t("App details from {host}.", { host: clientQuery.data.client_host })}
						</p>
					) : null}
					{clientQuery.data?.redirect_host ? (
						<p className="text-muted-foreground text-sm">
							{t("You will return to {host}.", { host: clientQuery.data.redirect_host })}
						</p>
					) : null}
					{clientQuery.data?.redirect_loopback ? (
						<p className="text-destructive text-sm">
							{t(
								"This sends you to an app on this computer. Only approve if you just started connecting from that app.",
							)}
						</p>
					) : null}
				</header>

				{isLoadingShell ? (
					<p className="text-muted-foreground text-sm">{t("Loading…")}</p>
				) : (
					<>
						{capCheck.atCap && existingPeer ? (
							<div
								role="status"
								className="rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-foreground text-sm"
							>
								<Trans
									text="Heads up: your Free plan's device limit is {count}. Approving will disconnect {name}, which will stop having access. {upgrade} to keep both connected."
									slots={{
										// Only Obsidian clients reach this (MCP is uncapped, #1974).
										count: capCheck.limit,
										name: <strong>{existingPeer.name ?? t("your existing connection")}</strong>,
										upgrade: (
											<a
												className="underline underline-offset-4"
												href={`${location.search}${settingsHash("billing")}`}
												onClick={(e) => {
													e.preventDefault();
													navigate(settingsTo("billing", location.search));
												}}
											>
												{t("Upgrade")}
											</a>
										),
									}}
								/>
							</div>
						) : null}
						{/* Pick, then a plain-language summary to approve. Same route,
						    so the OAuth params are untouched. */}
						<VaultAccessFlow
							access={access}
							vaults={live ?? []}
							legend={t("Which vaults can {client} access?", { client: clientName })}
							name={label.trim() || clientName}
							leveled={leveled}
							lockReadOnly={clientAskedReadOnly}
							backFocus={titleRef}
							fields={
								<label className="flex flex-col gap-1.5">
									<span className="font-medium text-foreground text-sm">
										<Trans
											text="Name this connection {optional}"
											slots={{
												optional: (
													<span className="font-normal text-muted-foreground">
														{t("(optional)")}
													</span>
												),
											}}
										/>
									</span>
									<Input
										type="text"
										maxLength={120}
										value={label}
										onChange={(e) => setLabel(e.target.value)}
										placeholder={clientName}
									/>
								</label>
							}
							confirmLabel={t("Approve")}
							pendingLabel={t("Approving…")}
							pending={submitting}
							onConfirm={handleApprove}
							// Cancel redirects from the query string: only a redirect the
							// backend confirmed gets one (an open redirect otherwise).
							onCancel={redirectVerified ? handleCancel : undefined}
							error={
								submitError ? (
									<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
										{submitError}
									</p>
								) : null
							}
						/>
					</>
				)}

				<Dialog open={showSwapConfirm} onOpenChange={setShowSwapConfirm}>
					<DialogContent className="sm:max-w-md">
						<DialogHeader>
							<DialogTitle>
								{t("Disconnect {name}?", {
									name: existingPeer?.name ?? t("your existing connection"),
								})}
							</DialogTitle>
							<DialogDescription>
								<Trans
									text="Your Free plan's device limit is {count}. Connecting {client} will disconnect {name}, which will stop having access to your Engram."
									slots={{
										// Only Obsidian clients reach this (MCP is uncapped, #1974).
										count: capCheck.limit,
										client: <strong>{clientName}</strong>,
										name: <strong>{existingPeer?.name ?? t("your existing connection")}</strong>,
									}}
								/>
							</DialogDescription>
						</DialogHeader>
						<DialogFooter className="sm:flex-col sm:justify-stretch sm:gap-2">
							<Button
								type="button"
								onClick={async () => {
									setShowSwapConfirm(false);
									await runSubmit(true);
								}}
								// Mirrors Approve's guard. Unreachable today (the dialog only
								// opens from an already-guarded Approve and the overlay blocks
								// the checkboxes behind it), but this is a second submit path
								// to the same endpoint and its safety must not depend on
								// modal-blocking behaviour staying true forever.
								disabled={submitting || reachesNothing}
								className="w-full"
							>
								{submitting
									? t("Connecting…")
									: t("Disconnect & connect {client}", { client: clientName })}
							</Button>
							<Button
								type="button"
								variant="outline"
								onClick={() => {
									setShowSwapConfirm(false);
									navigate(settingsTo("billing", location.search));
								}}
								disabled={submitting}
								className="w-full"
							>
								{t("Upgrade instead")}
							</Button>
						</DialogFooter>
					</DialogContent>
				</Dialog>
			</AuthPanel>
		</AuthShell>
	);
}
