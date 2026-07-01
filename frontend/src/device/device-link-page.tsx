import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { destructiveAlert, fieldInput, heading, selectableRow } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { setActiveVaultId } from "../api/active-vault";
import { api } from "../api/client";
import { type Connection, useBillingStatus, useConnections, useMe } from "../api/queries";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { connectionId as obsidianConnectionId } from "../billing/existing-connections-panel";
import { useConnectionCap } from "../billing/use-connection-cap";
import AuthPanel from "../layout/auth-panel";
import AuthShell from "../layout/auth-shell";
import { SyncStatusPill } from "../onboarding/sync-status-pill";
import { useVaultReadyEvents } from "../onboarding/use-vault-ready-events";

type Vault = { id: string; name: string; note_count: number };

type Step = "enter-code" | "pick-vault" | "success" | "error";

export default function DeviceLinkPage() {
	const { isSignedIn } = useAuthAdapter();
	const navigate = useNavigate();
	const qc = useQueryClient();
	const [step, setStep] = useState<Step>("enter-code");
	// RFC 8628 verification_uri_complete: if the plugin sends the user to
	// /link?code=ENGR-7X4K, prefill the field instead of forcing a re-type.
	const [userCode, setUserCode] = useState(() => {
		if (typeof window === "undefined") return "";
		const raw = new URLSearchParams(window.location.search).get("code") ?? "";
		const clean = raw
			.toUpperCase()
			.replace(/[^A-Z2-9]/gu, "")
			.slice(0, 8);
		return clean.length === 8 ? `${clean.slice(0, 4)}-${clean.slice(4)}` : clean;
	});
	const [vaults, setVaults] = useState<Vault[]>([]);
	// `selection` is the radio-row value: 'matched' (create new with the
	// plugin-suggested name), 'custom' (create new with the input below), or
	// the existing vault id as a string.
	const [selection, setSelection] = useState<string>("matched");
	const [suggestedName, setSuggestedName] = useState("");
	const [customName, setCustomName] = useState("");
	const [linkedVaultId, setLinkedVaultId] = useState<string | null>(null);
	const [error, setError] = useState("");
	const [loading, setLoading] = useState(false);
	// Device-flow is "I'm moving in" not "I want a 4th tab" — when at cap, we
	// DON'T block the flow. We warn the user the existing device will stop
	// syncing, and on Authorize we disconnect it first and then link this one.
	const capCheck = useConnectionCap("obsidian");
	// Only need the existing-connection details when at cap (for the heads-up
	// banner + the implicit disconnect on Authorize).
	const connections = useConnections({ enabled: capCheck.atCap });
	const existingObsidian = (connections.data ?? []).find(
		(c): c is Connection => c.kind === "obsidian",
	);
	// Vault cap awareness for the picker — Free has vaults_cap=1, so once the
	// user has any vault, the "create new" options would 402 on submit. Disable
	// them proactively and force a link-into-existing choice.
	const { data: billing } = useBillingStatus();
	const vaultsCap = billing?.caps.vaults ?? null;
	const atVaultCap = typeof vaultsCap === "number" && vaultsCap > 0 && vaults.length >= vaultsCap;

	if (!isSignedIn) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>Link Obsidian Vault</h1>
					<p className="text-sm text-muted-foreground">
						Please sign in to link your Obsidian vault.
					</p>
				</AuthPanel>
			</AuthShell>
		);
	}

	async function handleVerifyCode() {
		const formatted = userCode.toUpperCase().replace(/[^A-Z2-9]/gu, "");
		if (formatted.length !== 8) {
			setError("Code must be 8 characters (e.g., ENGR-7X4K)");
			return;
		}

		setLoading(true);
		setError("");
		try {
			const formattedCode = formatted.slice(0, 4) + "-" + formatted.slice(4);
			const data = await api.get<{ vaults: Vault[]; suggested_vault_name?: string | null }>(
				`/vaults?user_code=${encodeURIComponent(formattedCode)}`,
			);
			setUserCode(formattedCode);
			setVaults(data.vaults ?? []);
			const suggested = data.suggested_vault_name?.trim() || "";
			setSuggestedName(suggested);
			// Default selection:
			// - existing vault with the same name → pre-select that vault (link, don't dup)
			// - suggested name with no existing match → 'matched' (create new with that name)
			// - no hint at all → 'custom' (force user to type a name)
			const existing = suggested
				? (data.vaults ?? []).find((v) => v.name === suggested)
				: undefined;
			// If the user is at the Free vault cap, default to the first existing
			// vault (create-new rows are about to be disabled below).
			const fallbackExisting =
				(data.vaults ?? []).length >= (vaultsCap ?? Number.POSITIVE_INFINITY)
					? (data.vaults?.[0] ?? null)
					: null;
			setSelection(
				existing
					? existing.id
					: fallbackExisting
						? fallbackExisting.id
						: suggested
							? "matched"
							: "custom",
			);
			setStep("pick-vault");
		} catch {
			setError("Failed to load vaults. Please try again.");
		} finally {
			setLoading(false);
		}
	}

	const isMatched = selection === "matched";
	const isCustom = selection === "custom";
	const createNew = isMatched || isCustom;
	const effectiveNewName = isCustom ? customName.trim() : isMatched ? suggestedName : "";

	async function handleAuthorize() {
		setLoading(true);
		setError("");
		try {
			// If user is at cap, swap: disconnect the existing device first so the
			// authorize call doesn't 402. If the disconnect succeeds but authorize
			// fails, the user is left with 0 connections — surface that explicitly
			// instead of leaving them stranded silently.
			let swappedFromName: string | null = null;
			if (capCheck.atCap && existingObsidian) {
				const existingId = obsidianConnectionId(existingObsidian);
				if (existingId) {
					swappedFromName = existingObsidian.name ?? "previous device";
					await api.del(`/connections/device/${existingId}`);
					await qc.invalidateQueries({ queryKey: ["connections"] });
					await qc.invalidateQueries({ queryKey: ["billing", "status"] });
				}
			}

			const body = createNew
				? { user_code: userCode, vault_id: "new", vault_name: effectiveNewName }
				: { user_code: userCode, vault_id: selection };

			try {
				const { vault_id } = await api.post<{ ok: boolean; vault_id: string }>(
					"/auth/device/authorize",
					body,
				);
				// Stash the linked vault as active so subsequent navigations land in
				// the right one. We DON'T auto-navigate immediately — the plugin still
				// owes the first sync from inside Obsidian. The success step listens
				// for the `vault_populated` broadcast and forwards then.
				setActiveVaultId(vault_id);
				setLinkedVaultId(vault_id);
				qc.invalidateQueries({ queryKey: ["vaults"] });
				setStep("success");
			} catch (authErr) {
				if (swappedFromName) {
					// Disconnect succeeded but authorize did not — user is now at 0
					// connections instead of 1. Make that visible.
					setError(
						`Disconnected '${swappedFromName}' but linking the new device failed. ` +
							"Re-link from Obsidian — no devices are currently synced.",
					);
					return;
				}
				throw authErr;
			}
		} catch (e: unknown) {
			// LimitExceededError is surfaced by UpgradeDialogProvider (the cap
			// dialog opens with Disconnect + Upgrade). Don't double-render its
			// raw message as an inline error.
			if (e instanceof Error && e.name === "LimitExceededError") {
				return;
			}
			const message = e instanceof Error ? e.message : "Authorization failed";
			if (message.includes("404") || message.includes("not found")) {
				setError("This code is invalid or has expired. Please try again from Obsidian.");
			} else {
				setError(message);
			}
		} finally {
			setLoading(false);
		}
	}

	const canAuthorize = createNew ? effectiveNewName.length > 0 : true;

	return (
		<AuthShell>
			<AuthPanel
				className={cn(
					"flex flex-col gap-4",
					// pick-vault is a tighter, decision-focused step — narrow the
					// whole card so the radio rows + button don't feel oceanic.
					step === "pick-vault" && "mx-auto sm:w-4/5",
				)}
			>
				<h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
					{step === "pick-vault" ? "Choose a vault to sync" : "Link Obsidian Vault"}
				</h1>

				{capCheck.swapCooldownHours != null && step !== "success" ? (
					// Cooldown gates the Sync button (line 319) regardless of whether
					// an active device still exists — the backend rejects a new family
					// inside the swap window. Render the banner on cooldown alone, not
					// gated on `atCap`, so the disabled button always has its reason.
					<div
						role="alert"
						className="rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-foreground"
					>
						You recently swapped devices. Your Free plan allows 1 swap every 24 hours — you can swap
						again in {capCheck.swapCooldownHours}h.{" "}
						<a
							className="underline underline-offset-4"
							onClick={(e) => {
								e.preventDefault();
								navigate("/settings/billing");
							}}
							href="/settings/billing"
						>
							Upgrade
						</a>{" "}
						to connect as many devices as you like.
					</div>
				) : capCheck.atCap && existingObsidian && step !== "success" ? (
					<div
						role="status"
						className="rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-foreground"
					>
						Heads up — your Free plan syncs files between 1 device at a time. Linking this device
						will disconnect <strong>{describeObsidianDevice(existingObsidian)}</strong>, which will
						stop receiving sync changes.{" "}
						<a
							className="underline underline-offset-4"
							onClick={(e) => {
								e.preventDefault();
								navigate("/settings/billing");
							}}
							href="/settings/billing"
						>
							Upgrade
						</a>{" "}
						to keep both connected.
					</div>
				) : null}

				{step === "enter-code" && (
					<div className="flex flex-col gap-3">
						<p className="text-sm text-muted-foreground">
							Enter the code shown in your Obsidian plugin:
						</p>
						<input
							type="text"
							value={userCode}
							onChange={(e) => setUserCode(e.target.value.toUpperCase())}
							placeholder="XXXX-XXXX"
							maxLength={9}
							className={cn(fieldInput, "text-center font-mono text-2xl tracking-widest")}
							onKeyDown={(e) => e.key === "Enter" && handleVerifyCode()}
						/>
						<Button type="button" onClick={handleVerifyCode} disabled={loading} className="w-full">
							{loading ? "Verifying…" : "Verify"}
						</Button>
					</div>
				)}

				{step === "pick-vault" && (
					<div className="flex flex-col gap-3">
						<p className="text-sm text-muted-foreground">
							Pick an existing one, or create a new vault for these notes.
						</p>

						<VaultPickerFieldset
							vaults={vaults}
							suggestedName={suggestedName}
							selection={selection}
							onSelect={setSelection}
							customName={customName}
							onCustomChange={setCustomName}
							atVaultCap={atVaultCap}
						/>
						{atVaultCap && (
							<p className="text-xs text-muted-foreground">
								Your Free plan includes 1 vault — link into the existing one above, or{" "}
								<a
									className="underline underline-offset-4"
									href="/settings/billing"
									onClick={(e) => {
										e.preventDefault();
										navigate("/settings/billing");
									}}
								>
									upgrade
								</a>{" "}
								to create more.
							</p>
						)}

						<Button
							type="button"
							onClick={handleAuthorize}
							disabled={loading || !canAuthorize || capCheck.swapCooldownHours != null}
							className="w-full"
						>
							{loading ? "Syncing…" : "Sync"}
						</Button>
					</div>
				)}

				{step === "success" && (
					<SuccessStep linkedVaultId={linkedVaultId} onForward={() => navigate("/")} />
				)}

				{error && (
					<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
						{error}
					</p>
				)}
			</AuthPanel>
		</AuthShell>
	);
}

interface SuccessStepProps {
	linkedVaultId: string | null;
	onForward: () => void;
}

function SuccessStep({ linkedVaultId, onForward }: SuccessStepProps) {
	const { data: me } = useMe();
	const { vaultPopulated, vaultId } = useVaultReadyEvents({
		userId: me?.id ?? null,
		enabled: true,
	});

	// Auto-forward to the dashboard once the plugin's first sync lands. Match
	// on `linkedVaultId` so we only forward for THIS link session — broadcasts
	// from an unrelated vault won't shove us anywhere.
	useEffect(() => {
		if (vaultPopulated && vaultId != null && vaultId === linkedVaultId) {
			onForward();
		}
	}, [vaultPopulated, vaultId, linkedVaultId, onForward]);

	return (
		<div className="flex flex-col gap-4">
			<div className="flex flex-col gap-1">
				<h2 className="text-lg font-semibold text-foreground">Vault linked!</h2>
				<p className="text-sm text-foreground">
					Now jump back to Obsidian and run your first sync.
				</p>
			</div>

			<SyncStatusPill message="Waiting for your first sync…" />

			<p className="text-sm text-muted-foreground">
				Once it lands we'll take you to your vault automatically.
			</p>

			<Button type="button" variant="ghost" onClick={onForward} className="self-start text-sm">
				Skip ahead
			</Button>
		</div>
	);
}

interface VaultPickerFieldsetProps {
	vaults: Vault[];
	suggestedName: string;
	selection: string;
	onSelect: (next: string) => void;
	customName: string;
	onCustomChange: (next: string) => void;
	atVaultCap: boolean;
}

// Stacked-radio picker for the /link consent page. Three row variants:
//   1. Existing vault whose name matches the plugin's suggestion (top, if any)
//      — selecting it links into that vault, no creation.
//   2. Each other existing vault — explicit link target.
//   3. Custom-name row at the bottom with an inline input — focus or type
//      to auto-select.
// If no match-by-name exists and the plugin sent a suggestion, slot a
// "create with matched name" row at the top instead.
function VaultPickerFieldset({
	vaults,
	suggestedName,
	selection,
	onSelect,
	customName,
	onCustomChange,
	atVaultCap,
}: VaultPickerFieldsetProps) {
	const matchedExisting = suggestedName ? vaults.find((v) => v.name === suggestedName) : undefined;
	const otherVaults = matchedExisting ? vaults.filter((v) => v.id !== matchedExisting.id) : vaults;
	const isMatched = selection === "matched";
	const isCustom = selection === "custom";

	return (
		<fieldset className="flex flex-col gap-2">
			{matchedExisting ? (
				<label className={selectableRow(selection === matchedExisting.id)}>
					<input
						type="radio"
						name="vault-target"
						checked={selection === matchedExisting.id}
						onChange={() => onSelect(matchedExisting.id)}
						className="accent-primary"
					/>
					<span className="flex flex-col">
						<span className="text-sm font-medium text-foreground">{matchedExisting.name}</span>
						<span className="text-xs text-muted-foreground">
							Sync into your existing vault &middot; {matchedExisting.note_count} notes
						</span>
					</span>
				</label>
			) : (
				suggestedName &&
				!atVaultCap && (
					<label className={selectableRow(isMatched)}>
						<input
							type="radio"
							name="vault-target"
							checked={isMatched}
							onChange={() => onSelect("matched")}
							className="accent-primary"
						/>
						<span className="flex flex-col">
							<span className="text-sm font-medium text-foreground">{suggestedName}</span>
							<span className="text-xs text-muted-foreground">
								Makes a new vault matching your Obsidian vault name
							</span>
						</span>
					</label>
				)
			)}

			{otherVaults.map((v) => {
				const active = selection === v.id;
				return (
					<label key={v.id} className={selectableRow(active)}>
						<input
							type="radio"
							name="vault-target"
							checked={active}
							onChange={() => onSelect(v.id)}
							className="accent-primary"
						/>
						<span className="flex flex-col">
							<span className="text-sm font-medium text-foreground">{v.name}</span>
							<span className="text-xs text-muted-foreground">
								Sync into this existing vault &middot; {v.note_count} notes
							</span>
						</span>
					</label>
				);
			})}

			{!atVaultCap && (
				<label className={selectableRow(isCustom)}>
					<input
						type="radio"
						name="vault-target"
						checked={isCustom}
						onChange={() => onSelect("custom")}
						className="accent-primary"
					/>
					<span className="flex flex-1 flex-col gap-2">
						<span className="text-sm font-medium text-foreground">
							Create a vault with a custom name
						</span>
						<input
							type="text"
							value={customName}
							onChange={(e) => {
								onCustomChange(e.target.value);
								if (!isCustom) onSelect("custom");
							}}
							onFocus={() => onSelect("custom")}
							placeholder="choose a new name"
							maxLength={100}
							className={fieldInput}
						/>
					</span>
				</label>
			)}
		</fieldset>
	);
}

// Build a user-facing identifier for the Obsidian device that's about to be
// disconnected. We layer signals from the Connection record so the banner
// reads as specifically as the data allows:
//   "the device syncing your 'Notes' vault on macOS (last active 2 days ago)"
// Falls back to "your previous device" when nothing useful is available
// (e.g., a freshly seeded test row with no UA / no vault name).
function describeObsidianDevice(c: Connection): string {
	const parts: string[] = [];
	if (c.vault_name) parts.push(`the device syncing your '${c.vault_name}' vault`);
	const os = parseUserAgentOs(c.first_user_agent);
	if (os) parts.push(`on ${os}`);
	const since = relativeTime(c.last_used_at ?? c.connected_at);
	if (since) parts.push(`(last active ${since})`);
	if (parts.length === 0) return c.name ?? "your previous device";
	return parts.join(" ");
}

function parseUserAgentOs(ua: string | null): string | null {
	if (!ua) return null;
	if (/iphone|ipad|ipod/iu.test(ua)) return "iOS";
	if (/android/iu.test(ua)) return "Android";
	if (/mac os|macintosh/iu.test(ua)) return "macOS";
	if (/windows/iu.test(ua)) return "Windows";
	if (/linux/iu.test(ua)) return "Linux";
	return null;
}

function relativeTime(iso: string | null): string | null {
	if (!iso) return null;
	const then = new Date(iso).getTime();
	if (Number.isNaN(then)) return null;
	const secs = Math.max(0, Math.floor((Date.now() - then) / 1000));
	if (secs < 60) return "just now";
	const mins = Math.floor(secs / 60);
	if (mins < 60) return `${mins} minute${mins === 1 ? "" : "s"} ago`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`;
	const days = Math.floor(hours / 24);
	if (days < 30) return `${days} day${days === 1 ? "" : "s"} ago`;
	const months = Math.floor(days / 30);
	if (months < 12) return `${months} month${months === 1 ? "" : "s"} ago`;
	const years = Math.floor(months / 12);
	return `${years} year${years === 1 ? "" : "s"} ago`;
}
