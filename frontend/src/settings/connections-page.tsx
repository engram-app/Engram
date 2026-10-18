import { Eye, KeyRound, Pencil, Plug, Search } from "lucide-react";
import { useId, useRef, useState } from "react";
import {
	type AccessLevel,
	type AccessRequest,
	grantWithin,
	isReadOnlyScope,
} from "@/components/access-level-select";
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
import { accessStateOf, useVaultAccess } from "@/components/vault-access-fields";
import { VaultAccessFlow } from "@/components/vault-access-flow";
import { useAutofocus } from "@/hooks/use-autofocus";
import { useT } from "@/i18n/locale-provider";
import type { Translate } from "@/i18n/translate";
import type { UIText } from "@/i18n/ui-text";
import { copyToClipboard } from "@/lib/clipboard";
import { intlLocale } from "@/lib/intl-locale";
import { notify } from "@/lib/notify";
import { serverErrorMessage } from "@/lib/server-error";
import { cn } from "@/lib/utils";
import { SettingsSectionCard } from "@/settings/account/section-card";
import {
	type Connection,
	type CreatedApiKey,
	useAccessLevelsSupported,
	useBillingStatus,
	useConnections,
	useCreatePat,
	useRevokeDeviceConnection,
	useRevokeOauthConnection,
	useRevokePat,
	useUpdateConnectionAccess,
	useVaults,
} from "../api/queries";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import { TOOL_LABELS } from "../onboarding/onboarding-tools";
import { ToolMark } from "../onboarding/tool-icon";

// ── Tier caps ─────────────────────────────────────────────────

// Caps come from /billing/status which resolves UserLimitOverride +
// tier defaults via Engram.Billing.effective_limit/2. Don't re-derive
// from tier here, overrides (support comps, demo seeds) would render
// stale.
function useTierCaps() {
	const { data } = useBillingStatus();
	const tier = data?.tier ?? "free";
	const isFree = useIsFreeTier();
	return {
		tier,
		isFree,
		// No caps yet means no "n / limit", never a guessed number.
		obsidianCap: data?.caps?.obsidian_connections ?? null,
	};
}

// ── Page ──────────────────────────────────────────────────────

interface PendingRevoke {
	name: string;
	description: UIText;
	onConfirm: () => Promise<unknown>;
}

// Below this many connections a search field is pure clutter — every row
// is already on screen.
const SEARCH_THRESHOLD = 8;

// ── ConnectionCard ────────────────────────────────────────────

// The vault names a card shows, for search. `null` means every vault, NOT
// none, which the legacy label spells out as "All vaults".
function vaultSearchText(connection: Connection, t: Translate): string {
	return connection.vault_levels
		? connection.vault_levels
				.filter((l) => l.level !== "none")
				.map((l) => l.vault_name ?? "")
				.join(" ")
		: legacyVaultLabel(connection, t);
}

// A backend that predates levels sends only `vault_ids`.
function legacyVaultLabel(connection: Connection, t: Translate): string {
	return connection.vault_ids === null
		? t("All vaults")
		: connection.vault_ids
				// A name is null when the vault is gone or out of the caller's own
				// scope. OAuth grants narrow themselves when a vault is deleted, but
				// `api_key_vaults` rows outlive a soft delete until the purge worker
				// runs, so a restricted key can outlive its vault by up to the
				// 30-day restore window. Naming the state beats printing a raw UUID
				// — and the entry must still be COUNTED, because a key restricted to
				// one deleted vault would otherwise render empty and read as
				// unrestricted.
				.map((_id, i) => connection.vault_names?.[i] ?? t("(deleted vault)"))
				.join(", ");
}

// Prefer the catalog spelling once a slug is resolved. The backend passes the
// client's self-reported name through, and Claude Code registers as
// "Claude Code (<server>)" with a user-chosen suffix, so the raw string leaks a
// local config detail into a list of vendors. Same reasoning as the brand mark,
// already keyed on slug.
function displayName(connection: Connection, t: Translate): string {
	return (
		connection.label ??
		(connection.slug ? TOOL_LABELS[connection.slug] : null) ??
		connection.name ??
		t("Unnamed")
	);
}

// Access levels can be changed on a grant or a key created with them; a key
// from before levels (no `vault_levels`) cannot, and a device is not leveled.
function editable(connection: Connection): boolean {
	return (
		connection.kind !== "obsidian" && Boolean(connection.vault_levels && connection.new_vaults)
	);
}

// The visible words stay the start of the accessible name (voice control
// matches them); the hidden name says which row.
function EditAccessButton({ name, onClick }: { name: string; onClick: () => void }) {
	const { t } = useT();
	return (
		<Button type="button" variant="outline" onClick={onClick}>
			{t("Edit access")}
			<span className="sr-only"> {name}</span>
		</Button>
	);
}

// Names shown on a card before the rest fold into "+N more".
const CARD_NAMES = 3;

function names(list: string[], t: Translate): string {
	const rest = list.length - CARD_NAMES;
	const shown = list.slice(0, CARD_NAMES).join(", ");
	return rest > 0 ? `${shown} ${t("+{count} more", { count: rest })}` : shown;
}

// What a credential can do, one short line per level, in the review screen's
// words and icons. Every vault at one level (now and later) is one line.
function AccessLines({ connection, className }: { connection: Connection; className: string }) {
	const { t } = useT();
	const levels = connection.vault_levels;
	const later = connection.new_vaults;
	if (!(levels && later)) {
		return <p className={className}>{legacyVaultLabel(connection, t)}</p>;
	}
	const at = (level: AccessLevel) =>
		levels.filter((l) => l.level === level).map((l) => l.vault_name ?? t("(deleted vault)"));
	const everything = later !== "none" && levels.every((l) => l.level === later);
	const lines = (
		[
			["write", Pencil, t("Can read and change notes")],
			["read", Eye, t("Can read notes")],
		] as const
	)
		.map(([level, Icon, title]) => {
			const list = everything
				? level === later
					? [t("All vaults, including ones you create later")]
					: []
				: [...at(level), ...(later === level ? [t("Vaults you create later")] : [])];
			return { level, Icon, title, list };
		})
		.filter((line) => line.list.length > 0);
	if (lines.length === 0) {
		return <p className={className}>{t("No access")}</p>;
	}
	return (
		<ul className={cn("space-y-1", className)}>
			{lines.map(({ level, Icon, title, list }) => (
				<li key={level} className="flex items-start gap-2">
					<Icon aria-hidden className="mt-0.5 size-4 shrink-0" />
					<span className="min-w-0">
						<span className="sr-only">{title} </span>
						{names(list, t)}
					</span>
				</li>
			))}
		</ul>
	);
}

function ConnectionCard({
	connection,
	onRevoke,
	onEdit,
}: {
	connection: Connection;
	onRevoke: () => void;
	onEdit?: () => void;
}) {
	const { t, renderedLocale } = useT();
	const name = displayName(connection, t);
	const [open, setOpen] = useState(false);
	const detailsId = useId();
	const toggleText = open ? t("Hide details") : t("View details");

	// Phone: icon + name, access, then the buttons as a full-width bottom row.
	// sm and up: the buttons move to the name's row, on the right.
	return (
		<article className="grid grid-cols-[auto_minmax(0,1fr)] items-center gap-3 rounded-lg border border-border bg-card p-4 sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:p-5">
			{connection.kind === "pat" ? (
				<span
					aria-hidden
					className="flex size-10 shrink-0 items-center justify-center rounded bg-muted text-muted-foreground"
				>
					<KeyRound className="size-5" />
				</span>
			) : (
				<ToolMark
					slug={connection.verified ? connection.slug : null}
					className="flex size-10 shrink-0 items-center justify-center [&_svg]:size-7"
					fallback={
						connection.logo ? (
							<img src={connection.logo} alt="" className="size-10 shrink-0 rounded" />
						) : (
							<div
								className="flex size-10 shrink-0 items-center justify-center rounded bg-muted text-muted-foreground"
								aria-hidden
							>
								<Plug className="size-5" />
							</div>
						)
					}
				/>
			)}
			<h3 className="flex min-w-0 flex-wrap items-center gap-2 font-medium text-base text-foreground">
				<span className="min-w-0 break-words">{name}</span>
				{/* Anything not `verified` is a claim, including a slug derived
				    from the client's own name (a localhost client may call itself
				    "ChatGPT"). Provenance is spelled out under the details. */}
				{connection.kind === "mcp" && !connection.verified ? (
					<span className="rounded bg-muted px-1.5 py-0.5 font-normal text-muted-foreground text-xs">
						{t("unverified")}
					</span>
				) : null}
			</h3>
			<AccessLines
				connection={connection}
				className="col-span-2 text-muted-foreground text-sm sm:col-span-1 sm:col-start-2"
			/>
			<span className="col-span-2 flex flex-wrap gap-2 *:flex-1 sm:col-span-1 sm:col-start-3 sm:row-start-1 sm:*:flex-none">
				<Button
					type="button"
					variant="outline"
					aria-expanded={open}
					aria-controls={detailsId}
					onClick={() => setOpen((o) => !o)}
					// Visible text first, then the card's name: every card has these
					// buttons, and a screen reader's button list must tell them apart.
					aria-label={`${toggleText} ${name}`}
				>
					{toggleText}
				</Button>
				{onEdit && editable(connection) ? <EditAccessButton name={name} onClick={onEdit} /> : null}
				<Button
					type="button"
					variant="destructive"
					onClick={onRevoke}
					aria-label={`${t("Revoke")} ${name}`}
				>
					{t("Revoke")}
				</Button>
			</span>
			<dl
				id={detailsId}
				hidden={!open}
				className="col-span-full grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 gap-y-1 border-border border-t pt-3 text-muted-foreground text-xs [&_dt]:font-semibold"
			>
				{Boolean(connection.software_version) && (
					<>
						<dt>{t("Version:")}</dt>
						<dd>{connection.software_version}</dd>
					</>
				)}
				{connection.connected_at ? (
					<>
						<dt>{t("Connected:")}</dt>
						<dd>{new Date(connection.connected_at).toLocaleString(intlLocale(renderedLocale))}</dd>
					</>
				) : null}
				{connection.last_used_at ? (
					<>
						<dt>{t("Last active:")}</dt>
						<dd>{new Date(connection.last_used_at).toLocaleString(intlLocale(renderedLocale))}</dd>
					</>
				) : null}
				{Boolean(connection.scope) && (
					<>
						<dt>{t("Scopes:")}</dt>
						<dd>{connection.scope}</dd>
					</>
				)}
				{connection.kind === "mcp" && (
					<>
						<dt>{t("Identity:")}</dt>
						<dd>
							{/* Two different proofs, and the copy must not conflate them.
								    A redirect-verified client proved itself by where the
								    sign-in code is delivered; a CIMD client proved itself by
								    publishing a document at a domain it owns, which is how a
								    loopback app can be verified at all. Saying "redirects to
								    a domain the vendor owns" about Claude Code would be
								    plainly false — it redirects to localhost.

								    `verified` gates BOTH "Verified." strings; `cimd_url` only
								    chooses which proof to name. Branching on cimd_url alone
								    would duplicate the backend's verification rule here, in
								    another language, with nothing keeping the two in sync — so
								    loosening SsrfGuard or lookup_by_cimd could make this claim
								    verification the backend never granted. The server stays
								    the only thing that decides `verified`. */}
							{connection.verified && connection.cimd_url
								? t("Verified. The app publishes its identity at a domain it owns.")
								: connection.verified
									? t("Verified. Sign-in redirects to a domain the vendor owns.")
									: connection.slug
										? t(
												"Self-reported. Local and self-hosted apps have no domain to check, so this is normal.",
											)
										: t(
												"Unrecognized client. Revoke it if you don't recognize the redirect below.",
											)}
						</dd>
					</>
				)}
				<dt>{t("Identifier:")}</dt>
				{/* For a CIMD client the URL *is* the public identifier, and unlike an
					    opaque UUID the user can check it by visiting it. The internal
					    client_id stays what the revoke button keys on. */}
				<dd className="break-all font-mono">
					{connection.cimd_url ?? connection.client_id ?? connection.key_id}
				</dd>
				{Boolean(connection.first_ip) && (
					<>
						<dt>{t("First IP:")}</dt>
						<dd>{connection.first_ip}</dd>
					</>
				)}
				{Boolean(connection.first_user_agent) && (
					<>
						<dt>{t("User agent:")}</dt>
						<dd className="break-all">{connection.first_user_agent}</dd>
					</>
				)}
				{/* Two different things, deliberately labelled apart. "Delivered to"
					    is where this grant's code actually went and is what the verified
					    badge is computed from; the registered list is only what the
					    client declared it might use. Merging them is what made a rogue
					    grant look like Claude (#1204). */}
				{Boolean(connection.redirect_uri) && (
					<>
						<dt>{t("Delivered to:")}</dt>
						<dd className="break-all font-mono">{connection.redirect_uri}</dd>
					</>
				)}
				{connection.redirect_uris.length > 0 && (
					<>
						<dt>{t("Registered redirects:")}</dt>
						<dd className="break-all">{connection.redirect_uris.join(", ")}</dd>
					</>
				)}
			</dl>
		</article>
	);
}

// ── EmptyState ────────────────────────────────────────────────

function EmptyState({ text }: { text: string }) {
	return (
		<section className="rounded-lg border-2 border-input border-dashed p-8 text-center">
			<p className="text-muted-foreground text-sm">{text}</p>
		</section>
	);
}

// ── PatSection ────────────────────────────────────────────────

function PatSection({
	pats,
	total,
	filtering,
	onRevoke,
	onEdit,
}: {
	pats: Connection[];
	// The unfiltered count. The heading reports what the user HAS, not how many
	// rows a search left standing.
	total: number;
	filtering: boolean;
	onRevoke: (pat: Connection) => void;
	onEdit: (pat: Connection) => void;
}) {
	const { t } = useT();

	const [showCreate, setShowCreate] = useState(false);
	const [newKey, setNewKey] = useState<{ key: string; id: string; name: string } | null>(null);

	return (
		<SettingsSectionCard
			title={t("API keys ({total})", { total })}
			headerAction={<Button onClick={() => setShowCreate(true)}>{t("+ New Key")}</Button>}
		>
			{pats.length === 0 ? (
				<EmptyState
					text={
						filtering
							? t("No matches.")
							: t("No API keys yet. Generate one to connect scripts or external tools.")
					}
				/>
			) : (
				<ul className="space-y-3">
					{pats.map((p) => (
						<li key={p.key_id}>
							<ConnectionCard
								connection={p}
								onEdit={() => onEdit(p)}
								onRevoke={() => onRevoke(p)}
							/>
						</li>
					))}
				</ul>
			)}

			{Boolean(showCreate) && (
				<CreatePatModal
					onClose={() => setShowCreate(false)}
					onCreated={(k) => {
						setNewKey(k);
						setShowCreate(false);
					}}
				/>
			)}

			{newKey ? <RevealKeyModal createdKey={newKey} onClose={() => setNewKey(null)} /> : null}
		</SettingsSectionCard>
	);
}

// ── CreatePatModal ────────────────────────────────────────────

function CreatePatModal({
	onClose,
	onCreated,
}: {
	onClose: () => void;
	onCreated: (k: CreatedApiKey) => void;
}) {
	const { t } = useT();
	const [name, setName] = useState("");
	const create = useCreatePat();
	const revoke = useRevokePat();
	const nameRef = useAutofocus<HTMLInputElement>();
	const access = useKeyAccess();
	// A key the backend stored wider than asked: "deleted" once revoked, or
	// "kept" when the revoke itself failed and the user must remove it.
	const [widened, setWidened] = useState<"deleted" | "kept" | null>(null);

	async function submit() {
		if (name.trim().length === 0) {
			return;
		}
		setWidened(null);
		const requested = access.params();
		try {
			const created = await create.mutateAsync({ name: name.trim(), ...requested });
			// The backend echoes what it stored. When levels were asked for, a
			// missing or wider echo is a key the user did not choose: delete it
			// before it is ever shown. (Asking for nothing is a key on every
			// vault, which no echo can exceed.)
			const asked = requested.vault_access || requested.default_access;
			if (
				asked &&
				!grantWithin(
					created,
					requested,
					access.vaults.map((v) => String(v.id)),
				)
			) {
				try {
					await revoke.mutateAsync(created.id);
					setWidened("deleted");
				} catch {
					setWidened("kept");
				}
				return;
			}
			onCreated(created);
		} catch {
			/* error surfaced via create.error */
		}
	}

	return (
		<ModalShell onClose={onClose} title={t("New API Key")} wide>
			{/* A flex column whose vault list gives way first, so the dialog fits
			    the viewport; it scrolls inside only as a last resort. */}
			<section className="flex min-h-0 flex-col gap-4 overflow-y-auto">
				<VaultAccessFlow
					access={access.access}
					vaults={access.vaults}
					legend={t("Vault access")}
					name={name.trim()}
					leveled={access.supported}
					picker={access.supported}
					ready={name.trim().length > 0}
					backFocus={nameRef}
					fields={
						<label className="block">
							<span className="font-medium text-foreground text-sm">{t("Name")}</span>
							<Input
								ref={nameRef}
								value={name}
								onChange={(e) => setName(e.target.value)}
								placeholder={t("e.g. ci-bot")}
								maxLength={64}
								className="mt-1 block"
							/>
							<span className="mt-1 block text-muted-foreground text-xs">
								{t("Helps you identify the key later, pick something memorable.")}
							</span>
						</label>
					}
					confirmLabel={t("Generate Key")}
					pendingLabel={t("Generating…")}
					pending={create.isPending}
					onConfirm={submit}
					onCancel={onClose}
					error={
						<>
							{Boolean(create.error) && (
								<p className="text-destructive text-sm" role="alert">
									{serverErrorMessage(create.error, t("Could not create key. Try again."), t)}
								</p>
							)}
							{widened ? (
								<p className="text-destructive text-sm" role="alert">
									{widened === "deleted"
										? t(
												"The server created a key with more access than you chose, so it was deleted. Try again, or contact support if this keeps happening.",
											)
										: t(
												"The server created a key with more access than you chose, and deleting it failed. Delete the key \u0022{name}\u0022 from your API keys.",
												{ name: name.trim() },
											)}
								</p>
							) : null}
						</>
					}
				/>
			</section>
		</ModalShell>
	);
}

// ── Key access (#332) ─────────────────────────────────────────

// One level on every vault (the default, Read and write = a key exactly as
// before levels), or a level per vault plus a policy for vaults created later.
// A key has no scope: it stores levels only.
function useKeyAccess() {
	const vaults = useVaults().data ?? [];
	// A backend that predates levels would ignore them and mint a full key, so
	// without its flag the form offers none and sends none.
	const supported = useAccessLevelsSupported();
	const access = useVaultAccess();

	return {
		access,
		vaults,
		supported,
		params: (): AccessRequest => {
			if (!supported) {
				return {};
			}
			const request = access.request(vaults.map((v) => String(v.id)));
			// All vaults at write is sent as no levels at all: a key exactly as
			// before levels.
			return !access.perVault && request.default_access === "write" ? {} : request;
		},
	};
}

// ── EditAccessModal ───────────────────────────────────────────

// The New API Key flow, pre-filled with what the credential has now. Saving
// replaces its access at once; the row in the list is swapped for the reply.
function EditAccessModal({
	connection,
	name,
	onClose,
}: {
	connection: Connection;
	name: string;
	onClose: () => void;
}) {
	const { t } = useT();
	const vaultsQuery = useVaults();
	const vaults = vaultsQuery.data ?? [];
	const update = useUpdateConnectionAccess();
	const titleRef = useRef<HTMLHeadingElement>(null);
	const access = useVaultAccess(
		accessStateOf(connection.vault_levels ?? [], connection.new_vaults ?? "none"),
	);
	const readOnly = isReadOnlyScope(connection.scope ?? "");
	const [error, setError] = useState<string | null>(null);

	async function save() {
		setError(null);
		try {
			await update.mutateAsync({
				connection,
				body: access.request(
					vaults.map((v) => String(v.id)),
					readOnly ? "read" : "write",
				),
			});
			notify.success(t("Access updated"));
			onClose();
		} catch (e) {
			setError(serverErrorMessage(e, t("Could not save these changes. Try again."), t));
		}
	}

	return (
		<ModalShell
			onClose={onClose}
			title={t("Edit access for {name}", { name })}
			titleRef={titleRef}
			wide
		>
			<section className="flex min-h-0 flex-col gap-4 overflow-y-auto">
				{/* Only a loaded list: an empty one would save no levels at all
				    and replace every level the user never saw on Review. */}
				{vaultsQuery.isSuccess ? (
					<VaultAccessFlow
						access={access}
						vaults={vaults}
						legend={t("Vault access")}
						name={name}
						fields={
							readOnly ? (
								<p className="text-muted-foreground text-sm">
									{t("This connection was approved as read only. Reconnect it to allow changes.")}
								</p>
							) : null
						}
						lockReadOnly={readOnly}
						settingsHint={false}
						backFocus={titleRef}
						confirmLabel={t("Save")}
						pendingLabel={t("Saving…")}
						pending={update.isPending}
						onConfirm={save}
						onCancel={onClose}
						error={
							error ? (
								<p className="text-destructive text-sm" role="alert">
									{error}
								</p>
							) : null
						}
					/>
				) : (
					<>
						{vaultsQuery.isError ? (
							<p className="text-destructive text-sm" role="alert">
								{serverErrorMessage(
									vaultsQuery.error,
									t("Could not load your vaults. Try again."),
									t,
								)}
							</p>
						) : (
							<p className="text-muted-foreground text-sm">{t("Loading…")}</p>
						)}
						<Button type="button" variant="outline" onClick={onClose}>
							{t("Cancel")}
						</Button>
					</>
				)}
			</section>
		</ModalShell>
	);
}

// ── RevealKeyModal ────────────────────────────────────────────

function RevealKeyModal({
	createdKey,
	onClose,
}: {
	createdKey: { key: string; id: string; name: string };
	onClose: () => void;
}) {
	const { t } = useT();
	const [copyState, setCopyState] = useState<"idle" | "copied" | "error">("idle");
	const keyFieldRef = useRef<HTMLInputElement>(null);

	async function copy() {
		const ok = await copyToClipboard(createdKey.key);
		setCopyState(ok ? "copied" : "error");
		if (ok) {
			setTimeout(() => setCopyState("idle"), 2000);
		}
	}

	function selectAll() {
		keyFieldRef.current?.select();
	}

	return (
		<ModalShell onClose={onClose} title={t("Save your API key")}>
			<div className="space-y-4">
				<p className="rounded-md bg-amber-50 px-3 py-2 text-amber-800 text-sm dark:bg-amber-950 dark:text-amber-200">
					{t(
						"This is the only time the key will be shown. Copy it now and store it somewhere safe.",
					)}
				</p>

				<div className="flex items-stretch gap-2">
					<Input
						ref={keyFieldRef}
						readOnly
						value={createdKey.key}
						onFocus={selectAll}
						onClick={selectAll}
						className="flex-1 bg-muted font-mono"
						aria-label={t("API key")}
					/>
					<Button type="button" onClick={copy} aria-label={t("Copy API key")}>
						<CopyIcon copied={copyState === "copied"} />
						<span className="min-w-12 text-left">
							{copyState === "copied" ? t("Copied") : t("Copy")}
						</span>
					</Button>
				</div>

				{copyState === "error" && (
					<p className="text-destructive text-sm" role="alert">
						{t("Copy failed, click the field and press Cmd/Ctrl+C to copy manually.")}
					</p>
				)}

				<footer className="flex justify-end pt-2">
					<Button type="button" variant="outline" onClick={onClose}>
						{t("Done")}
					</Button>
				</footer>
			</div>
		</ModalShell>
	);
}

// ── Shared helpers ────────────────────────────────────────────

function CopyIcon({ copied }: { copied: boolean }) {
	if (copied) {
		return (
			<svg
				xmlns="http://www.w3.org/2000/svg"
				viewBox="0 0 20 20"
				fill="currentColor"
				className="size-4"
				aria-hidden="true"
			>
				<path
					fillRule="evenodd"
					d="M16.704 5.293a1 1 0 010 1.414l-7.5 7.5a1 1 0 01-1.414 0l-3.5-3.5a1 1 0 111.414-1.414L8.5 12.086l6.79-6.793a1 1 0 011.414 0z"
					clipRule="evenodd"
				/>
			</svg>
		);
	}
	return (
		<svg
			xmlns="http://www.w3.org/2000/svg"
			viewBox="0 0 20 20"
			fill="currentColor"
			className="size-4"
			aria-hidden="true"
		>
			<path d="M7 3a2 2 0 00-2 2v9a2 2 0 002 2h6a2 2 0 002-2V5a2 2 0 00-2-2H7z" />
			<path d="M3 7a2 2 0 012-2h.5a.5.5 0 010 1H5a1 1 0 00-1 1v9a1 1 0 001 1h7a1 1 0 001-1v-.5a.5.5 0 011 0v.5a2 2 0 01-2 2H5a2 2 0 01-2-2V7z" />
		</svg>
	);
}

function ConfirmRevokeModal({
	name,
	description,
	onConfirm,
	onClose,
}: {
	name: string;
	description: UIText;
	onConfirm: () => Promise<unknown>;
	onClose: () => void;
}) {
	const { t } = useT();
	const [submitting, setSubmitting] = useState(false);
	const [error, setError] = useState<string | null>(null);

	async function handleConfirm() {
		setSubmitting(true);
		setError(null);
		try {
			await onConfirm();
			onClose();
		} catch (e) {
			setError(serverErrorMessage(e, t("Revoke failed"), t));
			setSubmitting(false);
		}
	}

	return (
		<Dialog
			open
			onOpenChange={(open) => {
				// Esc + outside-click route through here; ignore while the mutation
				// is in flight so the user can't accidentally close mid-request.
				if (!(open || submitting)) {
					onClose();
				}
			}}
		>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>{t("Revoke \u0022{name}\u0022?", { name })}</DialogTitle>
					<DialogDescription>{description}</DialogDescription>
				</DialogHeader>
				{Boolean(error) && (
					<p
						className="rounded-md bg-destructive/10 px-3 py-2 text-destructive text-sm"
						role="alert"
					>
						{error}
					</p>
				)}
				<DialogFooter>
					<Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
						{t("Cancel")}
					</Button>
					<Button type="button" variant="destructive" onClick={handleConfirm} disabled={submitting}>
						{submitting ? t("Revoking…") : t("Revoke access")}
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}

function ModalShell({
	title,
	onClose,
	children,
	wide = false,
	titleRef,
}: {
	title: UIText;
	onClose: () => void;
	children: React.ReactNode;
	// The vault access dialogs: room for the name, both boxes and the scrollbar.
	wide?: boolean;
	// Focus lands on the title when the dialog opens (and wherever the caller
	// sends it later), instead of on the first control.
	titleRef?: React.RefObject<HTMLHeadingElement | null>;
}) {
	return (
		<Dialog open onOpenChange={(open) => !open && onClose()}>
			<DialogContent
				showCloseButton={false}
				aria-describedby={undefined}
				onOpenAutoFocus={
					titleRef
						? (e) => {
								e.preventDefault();
								titleRef.current?.focus();
							}
						: undefined
				}
				// Escape in a search box with text clears the search (its own
				// handler) before it closes the dialog.
				onEscapeKeyDown={(e) => {
					const el = e.target;
					if (el instanceof HTMLInputElement && el.type === "search" && el.value) {
						e.preventDefault();
					}
				}}
				className={cn(
					"flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] flex-col gap-0 bg-card p-4 text-base sm:p-6",
					wide ? "max-w-xl" : "max-w-md",
				)}
			>
				<DialogHeader className="mb-4 shrink-0">
					<DialogTitle
						ref={titleRef}
						tabIndex={titleRef ? -1 : undefined}
						className="font-semibold text-lg outline-none"
					>
						{title}
					</DialogTitle>
				</DialogHeader>
				{children}
			</DialogContent>
		</Dialog>
	);
}

export default function ConnectionsPage() {
	const { t } = useT();
	const { data: connections, isLoading, error } = useConnections();
	const caps = useTierCaps();
	const revokeOauth = useRevokeOauthConnection();
	const revokeDevice = useRevokeDeviceConnection();
	const revokePat = useRevokePat();
	const [pendingRevoke, setPendingRevoke] = useState<PendingRevoke | null>(null);
	const [editing, setEditing] = useState<{ connection: Connection; name: string } | null>(null);
	// Same rule as the OAuth consent picker: a search field is clutter until
	// there is enough to search, and even then it stays behind a toggle rather
	// than sitting open above the thing it filters.
	const [searching, setSearching] = useState(false);
	const [filter, setFilter] = useState("");
	const searchRef = useRef<HTMLInputElement>(null);

	if (isLoading) {
		return <p className="text-muted-foreground text-sm">{t("Loading…")}</p>;
	}
	if (error) {
		return (
			<p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-destructive text-sm">
				{t("Failed to load: {message}", {
					message: serverErrorMessage(error, t("unknown error"), t),
				})}
			</p>
		);
	}

	const list = connections ?? [];
	const showSearch = list.length > SEARCH_THRESHOLD;
	const needle = showSearch ? filter.trim().toLowerCase() : "";
	// Name and vaults are what a row is recognized by, so they are what it is
	// found by.
	const matches = (c: Connection) =>
		!needle ||
		`${c.label ?? ""} ${c.name ?? ""} ${vaultSearchText(c, t)}`.toLowerCase().includes(needle);

	const shown = list.filter(matches);
	const obs = shown.filter((c) => c.kind === "obsidian");
	const mcp = shown.filter((c) => c.kind === "mcp");
	const pats = shown.filter((c) => c.kind === "pat");

	// Counted off the FULL list, never the filtered one: "1 / 1" is a plan cap
	// the user is at, and a filter must not make it read as though a slot freed
	// up.
	const obsTotal = list.filter((c) => c.kind === "obsidian").length;
	const mcpTotal = list.filter((c) => c.kind === "mcp").length;
	const obsCount = caps.obsidianCap === null ? `${obsTotal}` : `${obsTotal} / ${caps.obsidianCap}`;
	// Uncapped (#1974): a count, never "n / limit".
	const mcpCount = `${mcpTotal}`;

	return (
		<article className="space-y-8">
			<header>
				<div className="flex items-start justify-between gap-2">
					<h1 className="font-semibold text-foreground text-xl">{t("Connections")}</h1>
					{showSearch && !searching && (
						<Button
							type="button"
							variant="ghost"
							size="icon-sm"
							onClick={() => {
								setSearching(true);
								// Focus follows the click that opened the field, rather than
								// an autoFocus attribute stealing it on mount.
								requestAnimationFrame(() => searchRef.current?.focus());
							}}
							aria-label={t("Search connections")}
						>
							<Search />
						</Button>
					)}
				</div>
				<p className="mt-1 text-muted-foreground text-sm">
					{t("Manage what's connected to your Engram account.")}
				</p>
				{searching ? (
					<Input
						ref={searchRef}
						type="search"
						value={filter}
						onChange={(e) => setFilter(e.target.value)}
						onBlur={() => filter === "" && setSearching(false)}
						placeholder={t("Search connections")}
						aria-label={t("Search connections")}
						className="mt-3"
					/>
				) : null}
				<nav aria-label={t("Connection documentation")} className="mt-4 grid gap-2 sm:grid-cols-2">
					<a
						href="https://engram.page/docs/integrations/"
						target="_blank"
						rel="noreferrer"
						className="group rounded-lg border border-border bg-card p-3 hover:border-primary"
					>
						<p className="font-medium text-foreground text-sm group-hover:text-primary-ink">
							{t("AI integrations →")}
						</p>
						<p className="mt-0.5 text-muted-foreground text-xs">
							{t(
								"Step-by-step setup for Claude Desktop, Cursor, ChatGPT, and other AI apps that support custom integrations.",
							)}
						</p>
					</a>
					<a
						href="https://engram.page/docs/mcp/"
						target="_blank"
						rel="noreferrer"
						className="group rounded-lg border border-border bg-card p-3 hover:border-primary"
					>
						<p className="font-medium text-foreground text-sm group-hover:text-primary-ink">
							{t("MCP protocol →")}
						</p>
						<p className="mt-0.5 text-muted-foreground text-xs">
							{t("Connect Engram anywhere that supports MCP.")}
						</p>
					</a>
				</nav>
			</header>

			<SettingsSectionCard title={t("Obsidian plugins ({count})", { count: obsCount })}>
				{obs.length === 0 ? (
					<EmptyState
						text={
							needle
								? t("No matches.")
								: t("Install the Engram Vault Sync plugin in Obsidian to connect this vault.")
						}
					/>
				) : (
					<ul className="space-y-3">
						{obs.map((c) => (
							<li key={`${c.kind}-${c.client_id}`}>
								<ConnectionCard
									connection={c}
									onRevoke={() =>
										setPendingRevoke({
											name: c.name ?? t("this connection"),
											description: t("The plugin will lose access to your vault."),
											// Obsidian uses device-flow exclusively today; route all
											// Obsidian revocations through the device endpoint. When
											// MCP-style Obsidian clients ship we will need a
											// discriminator field from the backend.
											onConfirm: () => revokeDevice.mutateAsync(c.client_id!),
										})
									}
								/>
							</li>
						))}
					</ul>
				)}
			</SettingsSectionCard>

			<SettingsSectionCard title={t("AI tools & integrations ({count})", { count: mcpCount })}>
				{mcp.length === 0 ? (
					<EmptyState
						text={
							needle
								? t("No matches.")
								: t(
										"Connect Claude Desktop, Cursor, or another MCP client to use Engram as a tool.",
									)
						}
					/>
				) : (
					<ul className="space-y-3">
						{mcp.map((c) => (
							// Keyed on the grant, not the client: one client can hold
							// several grants, and they render as several rows.
							<li key={`${c.kind}-${c.family_id ?? c.client_id}`}>
								<ConnectionCard
									connection={c}
									onEdit={() => setEditing({ connection: c, name: displayName(c, t) })}
									onRevoke={() =>
										setPendingRevoke({
											name: c.name ?? t("this connection"),
											description: t("This client will lose access to your account."),
											// family_id scopes the revoke to THIS grant. Without it a
											// user with two grants for one client loses both.
											onConfirm: () =>
												revokeOauth.mutateAsync({
													clientId: c.client_id!,
													familyId: c.family_id,
												}),
										})
									}
								/>
							</li>
						))}
					</ul>
				)}
			</SettingsSectionCard>

			<PatSection
				pats={pats}
				total={list.filter((c) => c.kind === "pat").length}
				filtering={Boolean(needle)}
				onEdit={(p) => setEditing({ connection: p, name: displayName(p, t) })}
				onRevoke={(p) =>
					setPendingRevoke({
						name: p.name ?? t("this key"),
						description: t("This API key will stop working immediately and cannot be restored."),
						onConfirm: () => revokePat.mutateAsync(p.key_id!),
					})
				}
			/>

			{editing ? (
				<EditAccessModal
					connection={editing.connection}
					name={editing.name}
					onClose={() => setEditing(null)}
				/>
			) : null}

			{pendingRevoke ? (
				<ConfirmRevokeModal
					name={pendingRevoke.name}
					description={pendingRevoke.description}
					onConfirm={pendingRevoke.onConfirm}
					onClose={() => setPendingRevoke(null)}
				/>
			) : null}
		</article>
	);
}
