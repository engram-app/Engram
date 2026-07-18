import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { destructiveAlert, heading, selectableRow } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { api } from "../api/client";
import { fetchOAuthClient, type OAuthConsentParams, postOAuthConsent } from "../api/oauth";
import { type Connection, useConnections, useMe, useVaults } from "../api/queries";
import { connectionId as oauthConnectionId } from "../billing/existing-connections-panel";
import { useConnectionCap } from "../billing/use-connection-cap";
import AuthPanel from "../layout/auth-panel";
import AuthShell from "../layout/auth-shell";

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

type RequiredParam = (typeof REQUIRED_PARAMS)[number];

function readParams(search: URLSearchParams): {
	values: Record<RequiredParam, string> & { scope: string };
	resource: string | null;
	missing: RequiredParam[];
} {
	const values = {} as Record<RequiredParam, string> & { scope: string };
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

function buildCancelUrl(redirectUri: string, state: string): string {
	const sep = redirectUri.includes("?") ? "&" : "?";
	return `${redirectUri}${sep}error=access_denied&state=${encodeURIComponent(state)}`;
}

export default function OAuthAuthorizePage() {
	const [searchParams] = useSearchParams();
	const { values, resource, missing } = readParams(searchParams);

	const clientQuery = useQuery({
		queryKey: ["oauth-client", values.client_id],
		queryFn: () => fetchOAuthClient(values.client_id),
		enabled: missing.length === 0 && Boolean(values.client_id),
		retry: false,
	});

	const meQuery = useMe();
	const vaultsQuery = useVaults();
	const navigate = useNavigate();
	const qc = useQueryClient();

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

	const [vaultChoice, setVaultChoice] = useState<string>("vault:*");
	const [submitError, setSubmitError] = useState<string | null>(null);
	const [submitting, setSubmitting] = useState(false);
	// At-cap users get a confirm modal before the implicit swap so they see
	// EXACTLY what's about to be disconnected, not just an inline banner.
	const [showSwapConfirm, setShowSwapConfirm] = useState(false);

	useEffect(() => {
		if (vaultChoice === "vault:*" || !vaultsQuery.data) {
			return;
		}
		if (vaultChoice.startsWith("vault:")) {
			const id = vaultChoice.slice("vault:".length);
			const stillExists = id === "*" || vaultsQuery.data.some((v) => String(v.id) === id);
			if (!stillExists) {
				setVaultChoice("vault:*");
			}
		}
	}, [vaultsQuery.data, vaultChoice]);

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

		const body: OAuthConsentParams = {
			client_id: values.client_id,
			redirect_uri: values.redirect_uri,
			response_type: values.response_type,
			code_challenge: values.code_challenge,
			code_challenge_method: values.code_challenge_method,
			state: values.state,
			scope: values.scope,
			vault_choice: vaultChoice,
		};
		if (resource) {
			body.resource = resource;
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
			window.location.assign(redirect_uri);
		} catch (e: unknown) {
			if (swappedFromName) {
				// Disconnect succeeded but consent did not — user is now at 0
				// connections instead of 1. Make that visible.
				setSubmitError(
					`Disconnected '${swappedFromName}' but authorizing the new connection failed. ` +
						`Re-run the request from ${clientName} — no connections of this kind are currently active.`,
				);
				setSubmitting(false);
				return;
			}
			// LimitExceededError fallback is no longer expected on the at-cap path
			// (we pre-disconnected). Keep the guard for the rare race where the
			// cap re-trips between disconnect + consent.
			if (e instanceof Error && e.name === "LimitExceededError") {
				setSubmitting(false);
				return;
			}
			const message = e instanceof Error ? e.message : "Authorization failed";
			setSubmitError(message);
			setSubmitting(false);
		}
	};

	const handleCancel = () => {
		window.location.assign(buildCancelUrl(values.redirect_uri, values.state));
	};

	const clientName = clientQuery.data?.client_name ?? "this app";
	const isLoadingShell = clientQuery.isLoading || vaultsQuery.isLoading || meQuery.isLoading;

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
									href="/settings/billing"
									onClick={(e) => {
										e.preventDefault();
										navigate("/settings/billing");
									}}
								>
									Upgrade
								</a>{" "}
								to keep both connected.
							</div>
						) : null}
						<fieldset className="flex flex-col gap-2">
							<legend className="mb-1 font-medium text-foreground text-sm">Which vault?</legend>
							{vaultsQuery.data?.map((v) => {
								const value = `vault:${v.id}`;
								const active = vaultChoice === value;
								return (
									<label key={v.id} className={selectableRow(active)}>
										<input
											type="radio"
											name="vault_choice"
											value={value}
											checked={active}
											onChange={() => setVaultChoice(value)}
											className="accent-primary"
										/>
										<span className="font-medium text-foreground text-sm">{v.name}</span>
									</label>
								);
							})}
							<label className={selectableRow(vaultChoice === "vault:*")}>
								<input
									type="radio"
									name="vault_choice"
									value="vault:*"
									checked={vaultChoice === "vault:*"}
									onChange={() => setVaultChoice("vault:*")}
									className="accent-primary"
								/>
								<span className="font-medium text-foreground text-sm">All vaults</span>
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
								disabled={submitting}
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
								disabled={submitting}
								className="w-full"
							>
								{submitting ? "Connecting…" : `Disconnect & connect ${clientName}`}
							</Button>
							<Button
								type="button"
								variant="outline"
								onClick={() => {
									setShowSwapConfirm(false);
									navigate("/settings/billing");
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
