import obsidianMark from "@lobehub/icons-static-svg/icons/obsidian-color.svg?raw";
import { FilePlus2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Navigate, useNavigate } from "react-router";
import { useAutofocus } from "@/hooks/use-autofocus";
import AuthPanel from "@/layout/auth-panel";
import { heading } from "@/lib/ui-classes";
import { setActiveVaultId } from "../api/active-vault";
import {
	useCreateVault,
	useMe,
	useOnboardingStatus,
	useSetOnboardingProfile,
	useUpdateNote,
} from "../api/queries";
import { useConfig } from "../config-context";
import LoadingScreen from "../layout/loading-screen";
import { SyncStatusPill } from "./sync-status-pill";
import { useVaultReadyEvents } from "./use-vault-ready-events";
import { WELCOME_NOTE_CONTENT, WELCOME_NOTE_PATH } from "./welcome-note";

type Source = "obsidian" | "fresh" | null;

export default function OnboardVaultPage() {
	const navigate = useNavigate();
	const { data: status, isLoading } = useOnboardingStatus();
	const { data: me } = useMe();
	const setProfile = useSetOnboardingProfile();
	const createVault = useCreateVault();
	const updateNote = useUpdateNote();

	// Block render until status arrives so the source toggle never flashes
	// the wrong branch on first paint for a returning mid-flow user.
	if (isLoading || !status) {
		return <LoadingScreen />;
	}

	// Backend owns step ordering — if it says tools/agreement/billing should
	// come first, honor that. `:done` means wizard complete; kick home.
	if (status.next_step !== "vault" && status.next_step !== "done") {
		return <Navigate to={`/onboard/${status.next_step}`} replace />;
	}
	if (status.next_step === "done") {
		return <Navigate to="/" replace />;
	}

	return (
		<VaultStep
			profileSaved={status.profile_complete === true}
			savedUsesObsidian={status.profile?.uses_obsidian === true}
			userId={me?.id ?? null}
			setProfile={setProfile}
			createVault={createVault}
			updateNote={updateNote}
			navigate={navigate}
		/>
	);
}

interface VaultStepProps {
	profileSaved: boolean;
	savedUsesObsidian: boolean;
	userId: string | null;
	setProfile: ReturnType<typeof useSetOnboardingProfile>;
	createVault: ReturnType<typeof useCreateVault>;
	updateNote: ReturnType<typeof useUpdateNote>;
	navigate: ReturnType<typeof useNavigate>;
}

function VaultStep({
	profileSaved,
	savedUsesObsidian,
	userId,
	setProfile,
	createVault,
	updateNote,
	navigate,
}: VaultStepProps) {
	// Mid-flow refresh: if uses_obsidian was already POSTed in a prior visit,
	// pre-select that side so the user sees the inline panel for the branch
	// they picked instead of an empty source toggle.
	const [source, setSource] = useState<Source>(
		profileSaved ? (savedUsesObsidian ? "obsidian" : "fresh") : null,
	);
	// Track whether we've eager-committed `uses_obsidian: true` so the plugin's
	// first sync isn't blocked by RequireOnboarding. The gate skips the vault
	// check when uses_obsidian is true — without this, /api/notes 403s mid-sync
	// and `vault_populated` never fires.
	const [obsidianCommitted, setObsidianCommitted] = useState<boolean>(
		profileSaved && savedUsesObsidian,
	);

	async function pickSource(s: Source) {
		setSource(s);
		// Re-entry guard: a fast double-click on the Obsidian card would
		// otherwise dispatch two concurrent PATCHes. The `obsidianCommitted`
		// flag catches the steady state; `setProfile.isPending` catches the
		// racing-while-the-first-is-in-flight case.
		if (s === "obsidian" && !obsidianCommitted && !setProfile.isPending) {
			try {
				await setProfile.mutateAsync({ uses_obsidian: true });
				setObsidianCommitted(true);
			} catch {
				// Error is also reflected on setProfile.isError so the panel can
				// surface it; swallowing here just prevents a console unhandled
				// rejection. The user sees the inline error message below.
			}
		}
	}

	async function commitObsidian() {
		if (!obsidianCommitted) {
			await setProfile.mutateAsync({ uses_obsidian: true });
			setObsidianCommitted(true);
		}
		navigate("/", { replace: true });
	}

	async function commitFresh(name: string) {
		await setProfile.mutateAsync({ uses_obsidian: false });
		const trimmed = name.trim() || "My Vault";
		const { vault } = await createVault.mutateAsync({ name: trimmed });
		setActiveVaultId(vault.id);
		try {
			await updateNote.mutateAsync({
				path: WELCOME_NOTE_PATH,
				content: WELCOME_NOTE_CONTENT,
			});
		} catch {
			// Vault still exists if the welcome-note seed fails — let the user
			// proceed; an empty vault is recoverable, a missing vault is not.
		}
		navigate("/", { replace: true });
	}

	return (
		<SourceScreen
			source={source}
			onPickSource={pickSource}
			userId={userId}
			isCommitting={setProfile.isPending || createVault.isPending || updateNote.isPending}
			pickError={
				setProfile.isError && !obsidianCommitted
					? "Could not save your choice. Try clicking again — if it keeps failing, refresh the page."
					: null
			}
			onCommitObsidian={commitObsidian}
			onCommitFresh={commitFresh}
		/>
	);
}

// ── Source screen (with inline action panel) ──────────────────────────────────

interface SourceScreenProps {
	source: Source;
	onPickSource: (s: Source) => void;
	userId: string | null;
	isCommitting: boolean;
	pickError: string | null;
	onCommitObsidian: () => Promise<void>;
	onCommitFresh: (name: string) => Promise<void>;
}

function SourceScreen({
	source,
	onPickSource,
	userId,
	isCommitting,
	pickError,
	onCommitObsidian,
	onCommitFresh,
}: SourceScreenProps) {
	return (
		<AuthPanel className="flex flex-col gap-5">
			<header className="flex flex-col gap-2">
				<h1 className={heading}>Let's get your notes in.</h1>
				<p className="text-muted-foreground text-sm">
					If you have an Obsidian vault, we'll pull it in on the first connect. If not, we'll spin
					up a new vault for you.
				</p>
			</header>

			<div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
				<SourceCard
					icon={
						<span
							aria-hidden
							className="inline-flex h-6 w-6 shrink-0 items-center justify-center [&_svg]:h-full [&_svg]:w-full"
							dangerouslySetInnerHTML={{ __html: obsidianMark }}
						/>
					}
					title="I already use Obsidian"
					body="Install our plugin and your existing notes sync over on the first connect."
					selected={source === "obsidian"}
					onClick={() => onPickSource("obsidian")}
				/>
				<SourceCard
					icon={<FilePlus2 aria-hidden className="h-6 w-6 shrink-0 text-foreground" />}
					title="I'm starting fresh"
					body="We'll create your first vault right now. You can rename it or add more later from settings."
					selected={source === "fresh"}
					onClick={() => onPickSource("fresh")}
				/>
			</div>

			{pickError && (
				<p role="alert" className="text-destructive text-sm">
					{pickError}
				</p>
			)}

			{source === "obsidian" ? (
				<ObsidianInlinePanel
					userId={userId}
					isCommitting={isCommitting}
					onCommit={onCommitObsidian}
				/>
			) : source === "fresh" ? (
				<FreshInlinePanel isCommitting={isCommitting} onCommit={onCommitFresh} />
			) : null}
		</AuthPanel>
	);
}

interface SourceCardProps {
	icon: React.ReactNode;
	title: string;
	body: string;
	selected: boolean;
	onClick: () => void;
}

function SourceCard({ icon, title, body, selected, onClick }: SourceCardProps) {
	return (
		<button
			type="button"
			onClick={onClick}
			aria-pressed={selected}
			className={
				"group flex flex-col gap-2 rounded-xl border p-4 text-left transition sm:p-5" +
				(selected
					? "border-primary bg-accent/40"
					: "border-border bg-background hover:border-primary hover:bg-accent/30")
			}
		>
			<span className="flex items-center gap-2">
				{icon}
				<span className="font-semibold text-base text-foreground group-hover:text-primary">
					{title}
				</span>
			</span>
			<span className="text-muted-foreground text-sm">{body}</span>
		</button>
	);
}

// ── Obsidian inline panel ─────────────────────────────────────────────────────

interface ObsidianInlinePanelProps {
	userId: string | null;
	isCommitting: boolean;
	onCommit: () => Promise<void>;
}

function ObsidianInlinePanel({ userId, isCommitting, onCommit }: ObsidianInlinePanelProps) {
	const config = useConfig();
	const { vaultCreated, vaultPopulated, vaultId } = useVaultReadyEvents({
		userId,
		enabled: true,
	});

	// Auto-commit + activate once the plugin has actually written notes, so
	// the user is hands-off the moment their first sync lands.
	useEffect(() => {
		if (vaultPopulated && vaultId != null && !isCommitting) {
			setActiveVaultId(vaultId);
			void onCommit();
		}
	}, [vaultPopulated, vaultId, isCommitting, onCommit]);

	const stage: "waiting" | "detected" | "syncing" = vaultPopulated
		? "syncing"
		: vaultCreated
			? "detected"
			: "waiting";

	return (
		<div className="flex flex-col gap-4 rounded-xl border border-border bg-muted/30 p-4 sm:p-5">
			<h2 className="font-semibold text-foreground text-lg">
				Install the Engram Vault Sync plugin
			</h2>
			<ol className="flex list-decimal flex-col gap-3 pl-5 text-base text-foreground">
				<li>
					<div className="flex flex-col gap-1">
						<span>
							In Obsidian: <strong>Settings → Community plugins → Browse</strong>, search{" "}
							<em>Engram Vault Sync</em>, then install and enable it.
						</span>
						<span className="text-muted-foreground text-sm">
							Or open the{" "}
							<a
								href="https://community.obsidian.md/plugins/engram-vault-sync"
								target="_blank"
								rel="noreferrer noopener"
								className="font-medium text-primary underline-offset-2 hover:underline"
							>
								plugin listing
							</a>{" "}
							in your browser first.
						</span>
					</div>
				</li>
				{config.authProvider === "local" ? (
					<li>
						<div className="flex flex-col gap-1">
							<span>
								Open the plugin's <strong>🖥️ Self-hosted</strong> tab, enter your Engram server URL,
								and click <strong>Sign in</strong>.
							</span>
							<span className="text-muted-foreground text-sm">
								Use the same URL you used to reach this page.
							</span>
						</div>
					</li>
				) : (
					<li>
						Open the plugin's <strong>☁️ Cloud</strong> tab, click <strong>Sign in</strong>, and
						authenticate with your Engram account.
					</li>
				)}
				<li>
					Pick a vault to sync. The plugin creates a matching Engram vault and pushes your existing
					files.
				</li>
			</ol>
			<StatusRow stage={stage} />
		</div>
	);
}

function StatusRow({ stage }: { stage: "waiting" | "detected" | "syncing" }) {
	const labels: Record<typeof stage, string> = {
		waiting: "Waiting for the plugin to sign in…",
		detected: "Vault detected. Waiting for your first sync…",
		syncing: "Syncing your notes, almost there…",
	};
	return <SyncStatusPill message={labels[stage]} />;
}

// ── Fresh-start inline panel ──────────────────────────────────────────────────

interface FreshInlinePanelProps {
	isCommitting: boolean;
	onCommit: (name: string) => Promise<void>;
}

function FreshInlinePanel({ isCommitting, onCommit }: FreshInlinePanelProps) {
	const [name, setName] = useState("My Vault");
	const [error, setError] = useState<string | null>(null);
	const nameRef = useAutofocus<HTMLInputElement>();

	async function submit() {
		setError(null);
		try {
			await onCommit(name);
		} catch (err) {
			setError(err instanceof Error ? err.message : "Could not create vault");
		}
	}

	const disabled = isCommitting || name.trim().length === 0;

	return (
		<div className="flex flex-col gap-4 rounded-xl border border-border bg-muted/30 p-4 sm:p-5">
			<h2 className="font-semibold text-base text-foreground">Name your first vault</h2>
			<p className="text-muted-foreground text-sm">
				A vault is a folder for related notes. We'll seed it with a welcome note so the editor isn't
				empty when you arrive.
			</p>
			<label className="flex flex-col gap-2 text-sm">
				<span className="font-medium text-foreground">Vault name</span>
				<input
					ref={nameRef}
					type="text"
					value={name}
					onChange={(e) => setName(e.target.value)}
					maxLength={100}
					className="rounded-lg border border-border bg-background px-3 py-2 text-base text-foreground outline-none focus:border-primary focus:ring-2 focus:ring-primary/30"
				/>
			</label>
			{error ? (
				<p role="alert" className="text-destructive text-sm">
					{error}
				</p>
			) : null}
			<button
				type="button"
				onClick={submit}
				disabled={disabled}
				className="rounded-lg bg-primary px-4 py-2 font-medium text-primary-foreground text-sm transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
			>
				{isCommitting ? "Creating…" : "Create vault & continue"}
			</button>
		</div>
	);
}
