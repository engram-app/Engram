import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { useAutofocus } from "@/hooks/use-autofocus";
import { destructiveAlert, fieldInput, heading, selectableRow } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { setActiveVaultId } from "../api/active-vault";
import { api } from "../api/client";
import { type Connection, useBillingStatus, useConnections, useMe } from "../api/queries";
import { takeCredential } from "../auth/credential-handoff";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { connectionId as obsidianConnectionId } from "../billing/existing-connections-panel";
import { useConnectionCap } from "../billing/use-connection-cap";
import AuthPanel from "../layout/auth-panel";
import AuthShell from "../layout/auth-shell";
import { SyncStatusPill } from "../onboarding/sync-status-pill";
import { useVaultReadyEvents } from "../onboarding/use-vault-ready-events";
import { ROUTES } from "../routes";
import { settingsHash, settingsTo } from "../settings/settings-hash";

interface Vault {
	id: string;
	name: string;
	note_count: number;
}

type Step = "enter-code" | "verifying" | "pick-vault" | "success";

// The heading names the step you're on. It used to be a single ternary that
// only special-cased pick-vault, so the success screen kept announcing "Link
// Obsidian Vault" for a job that was already done.
const STEP_TITLES: Record<Step, string> = {
	"enter-code": "Link Obsidian Vault",
	// Same job as enter-code, just without the form — keep the same title so
	// the heading doesn't change under the user when the verify resolves.
	verifying: "Link Obsidian Vault",
	"pick-vault": "Choose a vault to sync",
	success: "Finish in Obsidian",
};

// RFC 8628 verification_uri_complete: the plugin sends the user to
// /link?code=ENGR-7X4K, so read and normalize the code it already knows.
// Returns "" when absent, and only returns the dashed 9-char form when the
// query held a full 8-character code — a partial value stays unformatted so
// the auto-verify below won't fire on it.
function readCodeFromQuery(search: string): string {
	const raw = new URLSearchParams(search).get("code") ?? "";
	const clean = raw
		.toUpperCase()
		.replace(/[^A-Z2-9]/gu, "")
		.slice(0, 8);
	return clean.length === 8 ? `${clean.slice(0, 4)}-${clean.slice(4)}` : clean;
}

function DeviceLinkPage() {
	const { isSignedIn } = useAuthAdapter();
	const navigate = useNavigate();
	const location = useLocation();
	const qc = useQueryClient();
	// Captured once at mount. `userCode` drifts as the user types, but whether
	// the code ARRIVED from the plugin is fixed — and only that earns an
	// automatic verify (see the effect below).
	// Read from the ROUTER's location, not window.location: the scrub below
	// goes through the router, so reading the raw window would leave the two
	// disagreeing about whether the code is still in the URL.
	// URL first, then the sign-in handoff. A signed-out arrival from the plugin
	// is redirected before this page ever renders, and the redirect strips the
	// code out of the URL — so for the most common case (first link, never
	// signed in on this browser) the handoff IS the code.
	const [urlCode] = useState(
		() =>
			readCodeFromQuery(location.search) ||
			readCodeFromQuery(`?code=${takeCredential("code", ROUTES.DEVICE_LINK)}`),
	);
	// Did the plugin hand us the code, or did the user type it? Only the first
	// skips RFC 8628's manual-entry speed bump, so only it needs the caution.
	const arrivedWithCode = urlCode.length === 9;
	// Arriving with a code means the code step has nothing left to ask, but the
	// verify behind it is async (it waits on /billing/status, then /vaults) —
	// so starting on "enter-code" painted a form the user never has to touch
	// and yanked it away a moment later. Start on the spinner instead and fall
	// BACK to the form only if the code turns out to be bad.
	const [step, setStep] = useState<Step>(arrivedWithCode ? "verifying" : "enter-code");
	// The code field is the only thing to do on that step, and the user usually
	// arrives from the plugin specifically to type into it — land with focus
	// already there. Keyed on the step so falling back to it re-focuses.
	const codeRef = useAutofocus<HTMLInputElement>(step === "enter-code");
	const [userCode, setUserCode] = useState(urlCode);
	const [vaults, setVaults] = useState<Vault[]>([]);
	// `selection` is the radio-row value: 'matched' (create new with the
	// plugin-suggested name), 'custom' (create new with the input below), or
	// the existing vault id as a string.
	const [selection, setSelection] = useState<string>("matched");
	const [suggestedName, setSuggestedName] = useState("");
	const [customName, setCustomName] = useState("");
	const [linkedVaultId, setLinkedVaultId] = useState<string | null>(null);
	// Whether the success step has a first-sync milestone to wait for. False when
	// linking into a vault that already has notes — see handleAuthorize.
	const [awaitFirstSync, setAwaitFirstSync] = useState(true);
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
	const { data: billing, isPending: billingPending } = useBillingStatus();
	const vaultsCap = billing?.caps.vaults ?? null;
	const atVaultCap = typeof vaultsCap === "number" && vaultsCap > 0 && vaults.length >= vaultsCap;

	// useCallback (not a plain function) so the auto-verify effect below can
	// depend on it without re-firing every render.
	const handleVerifyCode = useCallback(async () => {
		const formatted = userCode.toUpperCase().replace(/[^A-Z2-9]/gu, "");
		if (formatted.length !== 8) {
			setError("Code must be 8 characters (e.g., ENGR-7X4K)");
			return;
		}

		setLoading(true);
		setError("");
		try {
			const formattedCode = `${formatted.slice(0, 4)}-${formatted.slice(4)}`;
			const data = await api.get<{
				vaults: Vault[];
				suggested_vault_name?: string | null;
				user_code_valid?: boolean;
			}>(`/vaults?user_code=${encodeURIComponent(formattedCode)}`);
			// This endpoint answers 200 with the caller's vault list whether or not
			// the code is real — `user_code_valid` is the only validity signal, and
			// a null `suggested_vault_name` is NOT one (a valid code from a plugin
			// that sent no hint has both). Without this check every 8-character
			// string reached the vault picker and only failed at authorize.
			//
			// Compared against `false`, never falsy: a frontend deployed ahead of
			// the backend sees `undefined` here and must still let the link through.
			// Normalize the field before the validity branch: rejecting the code
			// used to leave "ZZZZZZZZ" sitting in an input that formats every
			// other value as "ZZZZ-ZZZZ".
			setUserCode(formattedCode);
			if (data.user_code_valid === false) {
				setError("This code is invalid or has expired. Please try again from Obsidian.");
				setStep("enter-code");
				return;
			}
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
			setStep("enter-code");
		} finally {
			setLoading(false);
		}
	}, [userCode, vaultsCap]);

	// The plugin already knows the code, so a complete link URL means the only
	// step left is choosing a vault — run the verify for them and land there.
	//
	// Deliberately does NOT authorize. Linking stays an explicit Sync click on a
	// screen that names the vault, which is the consent beat that makes carrying
	// the code in a URL safe (RFC 8628's device-code phishing concern is about
	// approving someone ELSE's code, and only a real consent screen defends it).
	//
	// Scrubs the code out of the address bar too: it's a single-use credential
	// and shouldn't sit in history or survive a copy-pasted URL.
	const autoVerified = useRef(false);
	useEffect(() => {
		// Wait for billing: `handleVerifyCode` picks the default selection using
		// `vaultsCap`, which is null until the query lands. The manual path is
		// never affected (typing takes longer than the fetch), but the auto path
		// fires at mount — and with a null cap an at-cap user defaulted to a
		// create-new row that is then rendered disabled, leaving Sync armed for
		// a guaranteed 402. `isPending` and not `data === undefined` so a FAILED
		// billing fetch still lets the link through.
		if (autoVerified.current || !isSignedIn || urlCode.length !== 9 || billingPending) {
			return;
		}
		autoVerified.current = true;
		// Scrub via the ROUTER, not window.history: the app runs on
		// createBrowserRouter, and a raw replaceState leaves react-router's own
		// location untouched — so `useLocation().search` kept the code, and the
		// billing links below (which preserve `search` on purpose) put the
		// credential straight back into the address bar and into history.
		// Delete only `code`; a blanket wipe would silently eat a future
		// redirect or auth-callback param.
		const scrubbed = new URLSearchParams(location.search);
		scrubbed.delete("code");
		navigate(
			{ pathname: location.pathname, search: scrubbed.toString(), hash: location.hash },
			{ replace: true },
		);
		handleVerifyCode();
	}, [isSignedIn, urlCode, handleVerifyCode, billingPending, location, navigate]);

	if (!isSignedIn) {
		return (
			<AuthShell>
				<AuthPanel className="flex flex-col gap-3">
					<h1 className={heading}>Link Obsidian Vault</h1>
					<p className="text-muted-foreground text-sm">
						Please sign in to link your Obsidian vault.
					</p>
				</AuthPanel>
			</AuthShell>
		);
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
				qc.invalidateQueries({ queryKey: ["vaults"] });

				// `vault_populated` fires on a vault's 0 -> 1 note transition, so a
				// vault that ALREADY has notes can never emit it.
				//
				// That kills the WAITING, not the step. The user still has to go back
				// to Obsidian and finish the sync, so the instructions and the Open
				// Obsidian button must render either way — skipping straight to the
				// vault drops the one thing this screen exists to tell them.
				const target = createNew ? null : vaults.find((v) => String(v.id) === String(selection));
				setAwaitFirstSync(!target || target.note_count === 0);

				setLinkedVaultId(vault_id);
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
				<h1 className="font-bold text-2xl text-foreground tracking-tight sm:text-3xl">
					{STEP_TITLES[step]}
				</h1>

				{capCheck.swapCooldownHours !== null && step !== "success" ? (
					// Cooldown gates the Sync button (line 319) regardless of whether
					// an active device still exists — the backend rejects a new family
					// inside the swap window. Render the banner on cooldown alone, not
					// gated on `atCap`, so the disabled button always has its reason.
					<div
						role="alert"
						className="rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-foreground text-sm"
					>
						You recently swapped devices. Your Free plan allows 1 swap every 24 hours — you can swap
						again in {capCheck.swapCooldownHours}h.{" "}
						<a
							className="underline underline-offset-4"
							onClick={(e) => {
								e.preventDefault();
								navigate(settingsTo("billing", location.search));
							}}
							href={`${location.search}${settingsHash("billing")}`}
						>
							Upgrade
						</a>{" "}
						to connect as many devices as you like.
					</div>
				) : capCheck.atCap && existingObsidian && step !== "success" ? (
					<div
						role="status"
						className="rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-foreground text-sm"
					>
						Heads up — your Free plan syncs files between 1 device at a time. Linking this device
						will disconnect <strong>{describeObsidianDevice(existingObsidian)}</strong>, which will
						stop receiving sync changes.{" "}
						<a
							className="underline underline-offset-4"
							onClick={(e) => {
								e.preventDefault();
								navigate(settingsTo("billing", location.search));
							}}
							href={`${location.search}${settingsHash("billing")}`}
						>
							Upgrade
						</a>{" "}
						to keep both connected.
					</div>
				) : null}

				{step === "enter-code" && (
					<div className="flex flex-col gap-3">
						<p className="text-muted-foreground text-sm">
							Enter the code shown in your Obsidian plugin:
						</p>
						<input
							ref={codeRef}
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

				{step === "verifying" && <SyncStatusPill message="Checking your code…" />}

				{step === "pick-vault" && (
					<div className="flex flex-col gap-3">
						<p className="text-muted-foreground text-sm">
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
						{Boolean(atVaultCap) && (
							<p className="text-muted-foreground text-xs">
								Your Free plan includes 1 vault — link into the existing one above, or{" "}
								<a
									className="underline underline-offset-4"
									href={`${location.search}${settingsHash("billing")}`}
									onClick={(e) => {
										e.preventDefault();
										navigate(settingsTo("billing", location.search));
									}}
								>
									upgrade
								</a>{" "}
								to create more.
							</p>
						)}

						{/* The typed-code step IS the phishing defence RFC 8628 §5.4 names,
						    and arriving with ?code= skips it. `vault_name` is
						    attacker-supplied (POST /api/auth/device is unauthenticated),
						    so the name shown above is NOT evidence of who is asking —
						    say so on the path that lost the speed bump. */}
						{arrivedWithCode && (
							<p className="text-muted-foreground text-xs">
								A device asked to sync with your account. Only continue if you started this from
								Obsidian &mdash; the vault name above was supplied by that device.
							</p>
						)}

						<Button
							type="button"
							onClick={handleAuthorize}
							disabled={loading || !canAuthorize || capCheck.swapCooldownHours !== null}
							className="w-full"
						>
							{loading ? "Syncing…" : "Sync"}
						</Button>
					</div>
				)}

				{step === "success" && (
					<SuccessStep
						linkedVaultId={linkedVaultId}
						obsidianVaultName={suggestedName}
						awaitFirstSync={awaitFirstSync}
						onForward={() => navigate("/")}
					/>
				)}

				{Boolean(error) && (
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
	// The LOCAL Obsidian vault name the plugin sent at device-flow start, which
	// is what `obsidian://open?vault=` addresses — not the server-side vault the
	// user just picked, whose name may differ. Empty when the plugin sent no hint.
	obsidianVaultName: string;
	// False when the linked vault already has notes: there is no 0 -> 1
	// transition left, so there is no `vault_populated` coming and promising an
	// automatic hand-off would be a lie.
	awaitFirstSync: boolean;
	onForward: () => void;
}

function SuccessStep({
	linkedVaultId,
	obsidianVaultName,
	awaitFirstSync,
	onForward,
}: SuccessStepProps) {
	const { data: me } = useMe();
	const { vaultPopulated, vaultId } = useVaultReadyEvents({
		userId: me?.id ?? null,
		// A non-empty vault has no 0->1 transition left, so the step below tells
		// the user there is no automatic hand-off. Opening the socket anyway
		// would have forwarded them regardless — doing the thing we just said
		// we wouldn't.
		enabled: awaitFirstSync,
	});

	// Auto-forward to the dashboard once the plugin's first sync lands. Match
	// on `linkedVaultId` so we only forward for THIS link session — broadcasts
	// from an unrelated vault won't shove us anywhere.
	useEffect(() => {
		if (vaultPopulated && vaultId !== null && vaultId === linkedVaultId) {
			onForward();
		}
	}, [vaultPopulated, vaultId, linkedVaultId, onForward]);

	return (
		<div className="flex flex-col gap-4">
			{/* No second heading here — the panel's h1 already says "Finish in
			    Obsidian", and "Vault linked!" underneath it was the same news twice. */}
			{/* text-base, not the text-sm used for hints on the earlier steps: this
			    is the one instruction on the screen, and at text-sm it read like
			    fine print the user could skip. */}
			<p className="text-base text-foreground">
				Your vault is linked. Obsidian is waiting for you to start the first sync.
			</p>

			{/* Only an empty vault has a 0 -> 1 transition left, so only an empty
			    vault can produce `vault_populated`. Showing a spinner and promising
			    an automatic hand-off anywhere else advertises something that is
			    never going to happen. */}
			{awaitFirstSync ? (
				<>
					<SyncStatusPill message="Waiting for your first sync…" />
					<p className="text-muted-foreground text-sm">
						We'll open your vault here the moment it lands.
					</p>
				</>
			) : (
				<p className="text-muted-foreground text-sm">
					Your notes will appear here as they sync. You can come back any time.
				</p>
			)}

			{/* Actions bottom-right, matching the footer pattern used elsewhere
			    (e.g. settings/connections-page.tsx). Secondary first, primary last.

			    Obsidian registers the `obsidian://` URI scheme, so the primary is a
			    plain link — no integration, no detection. Deliberately a button and
			    not an automatic redirect: browsers suppress protocol launches
			    without a user gesture, and there is no success callback, so nothing
			    here may depend on the jump having worked. It also opens Obsidian on
			    whatever machine the BROWSER is on, which is why the escape hatch
			    beside it is always present. */}
			<footer className="flex justify-end gap-2 pt-2">
				<Button type="button" variant="ghost" onClick={onForward} className="text-sm">
					Continue to web app
				</Button>
				{obsidianVaultName ? (
					<Button asChild>
						<a href={`obsidian://open?vault=${encodeURIComponent(obsidianVaultName)}`}>
							Open Obsidian
						</a>
					</Button>
				) : null}
			</footer>
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
						<span className="font-medium text-foreground text-sm">{matchedExisting.name}</span>
						<span className="text-muted-foreground text-xs">
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
							<span className="font-medium text-foreground text-sm">{suggestedName}</span>
							<span className="text-muted-foreground text-xs">
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
							<span className="font-medium text-foreground text-sm">{v.name}</span>
							<span className="text-muted-foreground text-xs">
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
						<span className="font-medium text-foreground text-sm">
							Create a vault with a custom name
						</span>
						<input
							type="text"
							value={customName}
							onChange={(e) => {
								onCustomChange(e.target.value);
								if (!isCustom) {
									onSelect("custom");
								}
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
	if (c.vault_name) {
		parts.push(`the device syncing your '${c.vault_name}' vault`);
	}
	const os = parseUserAgentOs(c.first_user_agent);
	if (os) {
		parts.push(`on ${os}`);
	}
	const since = relativeTime(c.last_used_at ?? c.connected_at);
	if (since) {
		parts.push(`(last active ${since})`);
	}
	if (parts.length === 0) {
		return c.name ?? "your previous device";
	}
	return parts.join(" ");
}

function parseUserAgentOs(ua: string | null): string | null {
	if (!ua) {
		return null;
	}
	if (/iphone|ipad|ipod/iu.test(ua)) {
		return "iOS";
	}
	if (/android/iu.test(ua)) {
		return "Android";
	}
	if (/mac os|macintosh/iu.test(ua)) {
		return "macOS";
	}
	if (/windows/iu.test(ua)) {
		return "Windows";
	}
	if (/linux/iu.test(ua)) {
		return "Linux";
	}
	return null;
}

function relativeTime(iso: string | null): string | null {
	if (!iso) {
		return null;
	}
	const then = new Date(iso).getTime();
	if (Number.isNaN(then)) {
		return null;
	}
	const secs = Math.max(0, Math.floor((Date.now() - then) / 1000));
	if (secs < 60) {
		return "just now";
	}
	const mins = Math.floor(secs / 60);
	if (mins < 60) {
		return `${mins} minute${mins === 1 ? "" : "s"} ago`;
	}
	const hours = Math.floor(mins / 60);
	if (hours < 24) {
		return `${hours} hour${hours === 1 ? "" : "s"} ago`;
	}
	const days = Math.floor(hours / 24);
	if (days < 30) {
		return `${days} day${days === 1 ? "" : "s"} ago`;
	}
	const months = Math.floor(days / 30);
	if (months < 12) {
		return `${months} month${months === 1 ? "" : "s"} ago`;
	}
	const years = Math.floor(months / 12);
	return `${years} year${years === 1 ? "" : "s"} ago`;
}

export default DeviceLinkPage;
