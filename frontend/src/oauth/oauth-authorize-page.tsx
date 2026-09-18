import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Search } from "lucide-react";
import type React from "react";
import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { destructiveAlert, heading, selectableRow } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { MCP_CLIENTS } from "../analytics/events";
import { track } from "../analytics/track";
import { api } from "../api/client";
import { fetchOAuthClient, type OAuthConsentParams, postOAuthConsent } from "../api/oauth";
import {
	type Connection,
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
import { settingsHash, settingsTo } from "../settings/settings-hash";
import { clearPendingAuthorization, stashPendingAuthorization } from "./pending-authorization";

const REQUIRED_PARAMS = [
	"client_id",
	"redirect_uri",
	"response_type",
	"code_challenge",
	"code_challenge_method",
	"state",
] as const;

// `scope` is OPTIONAL in an authorization request (RFC 6749 §4.1.1) and the
// backend already defaults an absent scope to "mcp" (Engram.OAuth.
// validate_authorization_request). Requiring it here rejected legal
// scope-less requests — Claude Code's MCP (re)connect flow omits it — with a
// dead-end "Invalid authorization request" page. Mirror the backend default.
const DEFAULT_SCOPE = "mcp";

// Above this many vaults the list gets a search box. Below it, the box is
// pure clutter — every vault is already on screen.
const SEARCH_THRESHOLD = 8;

type RequiredParam = (typeof REQUIRED_PARAMS)[number];

function readParams(search: URLSearchParams): {
	values: Record<RequiredParam, string> & { scope: string };
	resource: string | null;
	missing: RequiredParam[];
} {
	const values: Record<RequiredParam, string> & { scope: string } = {
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

	return { values, resource: search.get("resource"), missing };
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

function buildCancelUrl(redirectUri: string, state: string): string {
	const sep = redirectUri.includes("?") ? "&" : "?";
	return `${redirectUri}${sep}error=access_denied&state=${encodeURIComponent(state)}`;
}

function countLabel(notes?: number, files?: number): string {
	const parts = [`${(notes ?? 0).toLocaleString()} notes`];
	if (files) {
		parts.push(`${files.toLocaleString()} files`);
	}
	return parts.join(" · ");
}

// `pe-3` keeps the row borders clear of the overlaid scrollbar.
function VaultRows({ scroll, children }: { scroll: boolean; children: React.ReactNode }) {
	const rows = <div className={cn("flex flex-col gap-2", scroll && "pe-3")}>{children}</div>;
	return scroll ? <ScrollArea className="h-[19rem]">{rows}</ScrollArea> : rows;
}

export default function OAuthAuthorizePage() {
	const [searchParams] = useSearchParams();
	const { values, resource, missing } = readParams(searchParams);

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
		if (clientQuery.isLoading || clientQuery.isError) {
			return;
		}
		bounced.current = true;

		const slug = clientQuery.data?.slug ?? null;
		// The boolean is deliberately not surfaced. The copy below promises no
		// automatic return, so a failed stash needs no distinct rendering, and
		// `onboardingDoneTarget()` already falls back to "/" when nothing was
		// parked. Reading it into state here would also mean an effect that
		// synchronously sets state, which the render-compiler lint rejects.
		stashPendingAuthorization(location.search, slug, clientQuery.data?.client_name ?? null);

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
		location.search,
		navigate,
		onboarding,
		setProfile,
	]);

	// Nothing left to resume once they are through. A stash that outlives its
	// flow would divert a later, unrelated trip through the wizard.
	useEffect(() => {
		if (onboarding?.gate_ok) {
			clearPendingAuthorization();
		}
	}, [onboarding]);

	// Proactive cap check — kind comes from the OAuth client metadata so we
	// pick the right cap key (mcp vs obsidian). Default to "mcp" until the
	// client query resolves; this only matters for the loading transition,
	// since the cap panel is gated on `!isLoadingShell` too.
	const clientKind: "mcp" | "obsidian" = clientQuery.data?.kind ?? "mcp";
	const capCheck = useConnectionCap(clientKind);
	// Only need the existing-connection details when at cap (for the heads-up
	// banner + the implicit disconnect on Approve).
	const connections = useConnections({ enabled: capCheck.atCap });
	const existingPeer = (connections.data ?? []).find((c): c is Connection => c.kind === clientKind);

	// `null` = the explicit "All vaults" choice, which stays all-vaults as new
	// ones are created. A Set = exactly those ids. These are different grants,
	// so ticking every box by hand does NOT collapse to `null` — only the
	// "All vaults" control sets it. The two do render alike (see `active`
	// below); it is the state, not the checkmarks, that differs.
	const [picked, setPicked] = useState<Set<string> | null>(null);

	// Ids that no longer exist in the fetched list are dropped. That is a
	// function of the current list, so it is computed here rather than written
	// back into state from an effect one paint later.
	const live = vaultsQuery.data;
	const selected =
		picked && live
			? new Set([...picked].filter((id) => live.some((v) => String(v.id) === id)))
			: picked;

	// Every box reads as checked under "All vaults", so the first click on one
	// has to mean "all except this" — seeding from an empty Set would instead
	// narrow to the single vault the user was trying to remove.
	const toggle = (id: string) => {
		setPicked((prev) => {
			const next = new Set(prev ?? (live ?? []).map((v) => String(v.id)));
			if (next.has(id)) {
				next.delete(id);
			} else {
				next.add(id);
			}
			return next;
		});
	};
	// A picker with four vaults does not need a search box; one with forty is
	// unusable without it. Only the second case pays for the extra control.
	const [filter, setFilter] = useState("");
	const [searching, setSearching] = useState(false);
	const searchRef = useRef<HTMLInputElement>(null);
	const showFilter = (live?.length ?? 0) > SEARCH_THRESHOLD;
	const needle = filter.trim().toLowerCase();
	const shown =
		showFilter && needle
			? (live ?? []).filter((v) => v.name.toLowerCase().includes(needle))
			: (live ?? []);

	// Prefilled via `placeholder`, never `value`: an untouched default is not a
	// choice, and only a non-empty typed value is sent.
	const [label, setLabel] = useState("");
	const [submitError, setSubmitError] = useState<string | null>(null);
	const [submitting, setSubmitting] = useState(false);
	// At-cap users get a confirm modal before the implicit swap so they see
	// EXACTLY what's about to be disconnected, not just an inline banner.
	const [showSwapConfirm, setShowSwapConfirm] = useState(false);

	if (missing.length > 0) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>Invalid authorization request</h1>
					<div role="alert" className={destructiveAlert}>
						<p className="font-medium text-foreground">Missing required OAuth parameters:</p>
						<ul className="mt-2 list-inside list-disc text-muted-foreground">
							{missing.map((m) => (
								<li key={m}>
									<code>{m}</code>
								</li>
							))}
						</ul>
					</div>
					<p className="text-muted-foreground text-sm">
						This page should be opened via an OAuth client redirect, not directly.
					</p>
				</AuthPanel>
			</AuthShell>
		);
	}

	if (clientQuery.isError) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>Unknown OAuth client</h1>
					<div role="alert" className={destructiveAlert}>
						<p className="text-muted-foreground">
							The client requesting access is not registered with Engram.
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
					<h1 className={heading}>Finish setting up Engram</h1>
					{/* States the PURPOSE without promising an automatic return.
					    The stash is a no-op when storage is disabled or full, and
					    the previous copy ("you'll come straight back here")
					    guaranteed a comeback that then quietly ended on the
					    dashboard with the waiting client never mentioned again.
					    The wizard banner names the client and offers the cancel,
					    so under-promising here costs nothing. */}
					<p className="text-muted-foreground text-sm">
						Taking you to setup so you can finish connecting{" "}
						<span className="text-primary">{clientQuery.data?.client_name ?? "this app"}</span>.
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
			state: values.state,
			scope: values.scope,
		};
		if (resource) {
			body.resource = resource;
		}
		if (selected && selected.size > 0) {
			body.vault_ids = [...selected];
		}
		const trimmed = label.trim();
		if (trimmed) {
			body.label = trimmed;
		}

		// If swapping, disconnect the existing connection of the same kind
		// first so the consent call doesn't 402. Mirrors the /link page swap
		// shape — the confirm modal already named what's about to disconnect.
		let swappedFromName: string | null = null;
		try {
			if (isSwap && existingPeer) {
				const existingId = oauthConnectionId(existingPeer);
				if (existingId) {
					swappedFromName = existingPeer.name ?? "previous connection";
					const path =
						existingPeer.kind === "obsidian"
							? `/connections/device/${existingId}`
							: `/connections/oauth/${existingId}`;
					await api.del(path);
					await qc.invalidateQueries({ queryKey: ["connections"] });
					await qc.invalidateQueries({ queryKey: ["billing", "status"] });
				}
			}

			const { redirect_uri } = await postOAuthConsent(body);
			if (isMcp) {
				track("mcp_connect_succeeded", { client: mcpClient });
			}
			window.location.assign(redirect_uri);
		} catch (e: unknown) {
			if (swappedFromName) {
				// Disconnect succeeded but consent did not — user is now at 0
				// connections instead of 1. Make that visible.
				setSubmitError(
					`Disconnected '${swappedFromName}' but authorizing the new connection failed. ` +
						`Re-run the request from ${clientName} — no connections of this kind are currently active.`,
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
			const message = e instanceof Error ? e.message : "Authorization failed";
			setSubmitError(message);
			if (isMcp) {
				track("mcp_connect_failed", { client: mcpClient, reason: "unknown" });
			}
			setSubmitting(false);
		}
	};

	const handleCancel = () => {
		window.location.assign(buildCancelUrl(values.redirect_uri, values.state));
	};

	const clientName = clientQuery.data?.client_name ?? "this app";
	const isLoadingShell =
		clientQuery.isLoading ||
		vaultsQuery.isLoading ||
		meQuery.isLoading ||
		onboardingQuery.isLoading;

	return (
		<AuthShell>
			<AuthPanel className="flex flex-col gap-4">
				<header className="flex flex-col gap-1">
					<h1 className={heading}>
						Authorize <span className="text-primary">{clientName}</span>
					</h1>
					<p className="text-muted-foreground text-sm">
						This app is requesting access to your Engram.
						{meQuery.data ? ` Signed in as ${meQuery.data.email}.` : ""}
					</p>
				</header>

				{isLoadingShell ? (
					<p className="text-muted-foreground text-sm">Loading…</p>
				) : (
					<>
						{capCheck.atCap && existingPeer ? (
							<div
								role="status"
								className="rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-foreground text-sm"
							>
								Heads up — your Free plan allows 1 active{" "}
								{clientKind === "obsidian" ? "device" : "external connection"}. Approving will
								disconnect <strong>{existingPeer.name ?? "your existing connection"}</strong>, which
								will stop having access.{" "}
								<a
									className="underline underline-offset-4"
									href={`${location.search}${settingsHash("billing")}`}
									onClick={(e) => {
										e.preventDefault();
										navigate(settingsTo("billing", location.search));
									}}
								>
									Upgrade
								</a>{" "}
								to keep both connected.
							</div>
						) : null}
						<label className="flex flex-col gap-1.5">
							<span className="font-medium text-foreground text-sm">
								Name this connection{" "}
								<span className="font-normal text-muted-foreground">(optional)</span>
							</span>
							<input
								type="text"
								maxLength={120}
								value={label}
								onChange={(e) => setLabel(e.target.value)}
								placeholder={clientName}
								className="rounded-lg border border-border bg-background p-2.5 text-sm"
							/>
						</label>

						<fieldset className="flex flex-col gap-2">
							{/* The search field is the second text input on a screen whose
							    actual question is a list of checkboxes, so it stays behind
							    this toggle rather than sitting open. Long lists are the
							    minority case even among users who have enough vaults to
							    reach the threshold. */}
							<div className="mb-1 flex items-center justify-between gap-2">
								<legend className="font-medium text-foreground text-sm">
									Which vaults can {clientName} access?
								</legend>
								{showFilter && !searching && (
									<button
										type="button"
										onClick={() => {
											setSearching(true);
											// Focus follows the click that opened the field. An
											// `autoFocus` attribute would steal focus on mount
											// instead, which is a different and worse thing.
											requestAnimationFrame(() => searchRef.current?.focus());
										}}
										aria-label="Search vaults"
										className="rounded p-1 text-muted-foreground hover:text-foreground"
									>
										<Search className="size-4" />
									</button>
								)}
							</div>
							{searching ? (
								<>
									<input
										ref={searchRef}
										type="search"
										value={filter}
										onChange={(e) => setFilter(e.target.value)}
										onBlur={() => filter === "" && setSearching(false)}
										placeholder="Search vaults"
										aria-label="Search vaults"
										className="rounded-lg border border-border bg-background p-2 text-sm"
									/>
									{/* Filtering hides rows, it never changes the selection —
									    so with a needle typed the count is the only way to see
									    what is still checked off-screen. */}
									<p aria-live="polite" className="text-muted-foreground text-xs">
										{selected === null
											? "All vaults selected"
											: `${selected.size} of ${live?.length ?? 0} selected`}
									</p>
								</>
							) : null}
							{/* Caps at roughly five rows, then scrolls. "All vaults" is
							    deliberately outside this box: it is the choice the list is
							    an alternative to, and it must stay reachable without
							    scrolling past every vault. `pe-3` keeps the row borders clear
							    of the overlaid scrollbar. */}
							{/* Radix's viewport is `size-full`, so the Root needs a DEFINITE
							    height — `max-h` collapses it and the rows spill over the card.
							    A fixed height would leave a short list sitting in a mostly
							    empty box, so the wrapper only appears once the list is long
							    enough to scroll. Same condition as the search box: one
							    threshold decides "this list needs handling". "All vaults"
							    stays outside either way — it is the choice the list is an
							    alternative to, and must not need scrolling to reach. */}
							<VaultRows scroll={showFilter}>
								{shown.map((v) => {
									const id = String(v.id);
									const active = selected === null || selected.has(id);
									return (
										<label key={id} className={selectableRow(active)}>
											<input
												type="checkbox"
												checked={active}
												onChange={() => toggle(id)}
												className="accent-primary"
											/>
											<span className="flex min-w-0 flex-1 items-baseline gap-2">
												<span className="font-medium text-foreground text-sm">{v.name}</span>
												{v.is_default ? (
													<span className="text-muted-foreground text-xs">default</span>
												) : null}
												{v.description ? (
													<span className="truncate text-muted-foreground text-xs">
														{v.description}
													</span>
												) : null}
											</span>
											<span className="shrink-0 text-muted-foreground text-xs">
												{countLabel(v.note_count, v.attachment_count)}
											</span>
										</label>
									);
								})}
								{showFilter && needle && shown.length === 0 && (
									<p className="p-3 text-muted-foreground text-sm">No vaults match "{filter}".</p>
								)}
							</VaultRows>
							<hr className="my-2 border-border" />
							<label className={selectableRow(selected === null)}>
								<input
									type="radio"
									name="all_vaults"
									checked={selected === null}
									onChange={() => setPicked(null)}
									className="accent-primary"
								/>
								<span className="font-medium text-foreground text-sm">
									All vaults
									<span className="ml-2 font-normal text-muted-foreground text-xs">
										including any you create later
									</span>
								</span>
							</label>
						</fieldset>

						{Boolean(submitError) && (
							<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
								{submitError}
							</p>
						)}

						<div className="flex gap-3">
							<Button
								type="button"
								variant="outline"
								onClick={handleCancel}
								disabled={submitting}
								className="flex-1"
							>
								Cancel
							</Button>
							<Button
								type="button"
								onClick={handleApprove}
								disabled={submitting || (selected !== null && selected.size === 0)}
								className="flex-1"
							>
								{submitting ? "Approving…" : "Approve"}
							</Button>
						</div>
					</>
				)}

				<Dialog open={showSwapConfirm} onOpenChange={setShowSwapConfirm}>
					<DialogContent className="sm:max-w-md">
						<DialogHeader>
							<DialogTitle>
								Disconnect {existingPeer?.name ?? "your existing connection"}?
							</DialogTitle>
							<DialogDescription>
								Your Free plan allows 1 active{" "}
								{clientKind === "obsidian" ? "device" : "external connection"}. Connecting{" "}
								<strong>{clientName}</strong> will disconnect{" "}
								<strong>{existingPeer?.name ?? "your existing connection"}</strong>, which will stop
								having access to your Engram.
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
								disabled={submitting || (selected !== null && selected.size === 0)}
								className="w-full"
							>
								{submitting ? "Connecting…" : `Disconnect & connect ${clientName}`}
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
								Upgrade instead
							</Button>
						</DialogFooter>
					</DialogContent>
				</Dialog>
			</AuthPanel>
		</AuthShell>
	);
}
