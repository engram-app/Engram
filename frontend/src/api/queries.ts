import {
	keepPreviousData,
	type QueryClient,
	useMutation,
	useQuery,
	useQueryClient,
} from "@tanstack/react-query";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { api, ApiError } from "./client";
import {
	isSyntheticFolderId,
	syntheticFolderId,
	syntheticFolderPath,
} from "../viewer/tree/synthesize-folders";
import { useActiveVaultId } from "./active-vault";
import { useDemoVaultOptional } from "../onboarding/tour/demo-vault-provider";
import { collideBump } from "@/lib/collide-bump";

// Encode each path segment but preserve slashes so Phoenix's splat
// routes match. encodeURIComponent on a full path produces %2F, which
// Plug.Static rejects with 400 InvalidPathError before the router runs.
function encodePathSegments(path: string): string {
	return path.split("/").map(encodeURIComponent).join("/");
}

// Types matching backend JSON responses
//
// `name` carries the FULL folder path (e.g. `'top/sub'`) — load-bearing
// for legacy path-keyed consumers. `id` + `parent_id` were added by
// backend commit 935b7bbf so headless-tree can key nodes by id and
// discover tree shape via parent_id without parsing path strings.
export interface Folder {
	id: string;
	parent_id: string | null;
	name: string;
	count: number;
}

export interface NoteSummary {
	id: string;
	path: string;
	title: string;
	folder: string;
	tags: string[];
	version: number;
	mtime: string;
	created_at: string;
	updated_at: string;
}

export interface Note extends NoteSummary {
	content: string;
}

export interface SearchResult {
	// null for orphan path hits (Task 1 backend) — frontend should treat
	// these as non-clickable since there's no id-routable target.
	id: string | null;
	path: string;
	title: string;
	folder: string;
	heading_path: string | null;
	snippet: string;
	score: number;
	match_count: number;
}

export interface User {
	id: string;
	email: string;
	role: "admin" | "member";
	display_name: string | null;
}

// Query hooks

// Hoisted so React Query treats the select identity as stable; otherwise an
// inline arrow re-runs every render and returns a fresh array, breaking
// memoized consumers (e.g. useEngramTree's rebuild useEffect).
// The backend returns a null id for the synthetic root row (name === '') AND for
// every *derived* folder (one that exists only because notes live in it — no
// explicit marker row). Drop only the root row; give derived folders a stable
// synthetic id keyed on their path so the `Folder.id: string` contract holds and
// they aren't erased from the tree. synthesizeFolders then links parents/ancestors.
const selectFolders = (data: { folders: Array<Folder & { id: string | null }> }): Folder[] =>
	data.folders
		.filter((f) => f.name !== "")
		.map((f) => (f.id != null ? (f as Folder) : { ...f, id: syntheticFolderId(f.name) }));

export function useFolders() {
	const vaultId = useActiveVaultId();
	const demo = useDemoVaultOptional();
	const query = useQuery({
		queryKey: ["folders", vaultId],
		// Backend echoes a synthetic root row (`name === ""`, `id === null`) to
		// expose the count of root-level notes. The tree owns root notes via
		// `useFolderNotes('')`; drop the synthetic row so consumers only see real
		// folder markers + the `Folder.id: string` contract holds.
		queryFn: () => api.get<{ folders: Array<Folder & { id: string | null }> }>("/folders"),
		select: selectFolders,
		enabled: !demo?.active,
		// Folder listing decrypts every marker row server-side; without a
		// staleTime each remount/window-focus refetches it. Mutations and the
		// sync channel (channel.ts) invalidate this key, so 60s of staleness
		// only spans gaps nothing else would catch anyway.
		staleTime: FOLDER_NOTES_STALE_MS,
	});
	if (demo?.active) {
		// Demo folders use string ids; synthesize stable sentinel ids
		// (1-based index, `demo-folder-N`) so the Folder contract is
		// satisfied and ids don't collide with real backend uuids.
		// parent_id is derived from the path prefix — root-level demo
		// folders report `parent_id: null`.
		const pathToId = new Map(demo.folders.map((f, i) => [f.path, `demo-folder-${i + 1}`]));
		const data: Folder[] = demo.folders.map((f, i) => {
			const slash = f.path.lastIndexOf("/");
			const parentPath = slash < 0 ? null : f.path.slice(0, slash);
			return {
				id: `demo-folder-${i + 1}`,
				parent_id: parentPath === null ? null : (pathToId.get(parentPath) ?? null),
				name: f.path,
				count: demo.notes.filter((n) => n.folder_id === f.id).length,
			};
		});
		return { ...query, data, isLoading: false, isFetching: false, error: null };
	}
	return query;
}

const selectNotes = (data: { notes: NoteSummary[] }) => data.notes;

export function useFolderNotes(folder: string, options?: { enabled?: boolean }) {
	const vaultId = useActiveVaultId();
	const demo = useDemoVaultOptional();
	const query = useQuery({
		queryKey: ["folderNotes", vaultId, folder],
		queryFn: () =>
			api.get<{ notes: NoteSummary[] }>(`/folders/list?folder=${encodeURIComponent(folder)}`),
		select: selectNotes,
		enabled: !demo?.active && (options?.enabled ?? folder.length > 0),
		// Same contract as useFolderNotesById: mutations + channel events
		// invalidate; staleness only spans gaps those already don't cover.
		staleTime: FOLDER_NOTES_STALE_MS,
	});
	if (demo?.active) {
		const matchFolder = demo.folders.find((f) => f.path === folder);
		const notes: NoteSummary[] = matchFolder
			? demo.notes
					.filter((n) => n.folder_id === matchFolder.id)
					.map((n, i) => ({
						// Demo notes have string ids; synthesize sentinel ids
						// so they don't collide with real backend uuids and so the
						// NoteSummary contract is satisfied (id: string).
						id: `demo-note-${i + 1}`,
						path: n.path,
						title: n.title,
						folder: matchFolder.path,
						tags: [],
						version: 1,
						mtime: new Date().toISOString(),
						created_at: new Date().toISOString(),
						updated_at: new Date().toISOString(),
					}))
			: [];
		return { ...query, data: notes, isLoading: false, isFetching: false, error: null };
	}
	return query;
}

// Headless-tree consumers key folder nodes by id and fetch their note
// children via the by-id endpoint (Task 6). Path-keyed `useFolderNotes`
// stays in place for the dashboard folder-browse view; the tree reads
// everything (root + subfolders) through this one id-keyed cache so a
// note mutation only has to patch a single place.
// 60s of staleness keeps re-expansions instant while a `notes.batch` channel
// event (or any single-note mutation) still invalidates the key and refetches.
export const FOLDER_NOTES_STALE_MS = 60_000;

export interface AttachmentSummary {
	id: string;
	path: string;
	mime_type: string;
	size_bytes: number;
	mtime: number;
	updated_at: string;
}

const selectAttachments = (data: { attachments: AttachmentSummary[] }) => data.attachments;

export function useAttachments() {
	const vaultId = useActiveVaultId();
	const demo = useDemoVaultOptional();
	const query = useQuery({
		queryKey: ["attachments", vaultId],
		queryFn: () => api.get<{ attachments: AttachmentSummary[] }>("/attachments"),
		select: selectAttachments,
		enabled: !demo?.active,
		staleTime: FOLDER_NOTES_STALE_MS,
	});
	// Demo vaults carry no binary attachments.
	if (demo?.active) {
		return {
			...query,
			data: [] as AttachmentSummary[],
			isLoading: false,
			isFetching: false,
			error: null,
		};
	}
	return query;
}

export function useUploadAttachment() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ attachment: AttachmentSummary },
		Error,
		{ path: string; mime_type?: string; content_base64: string; mtime: number }
	>({
		mutationFn: (body) => api.post<{ attachment: AttachmentSummary }>("/attachments", body),
		onSuccess: () => {
			// New attachment row changes the tree's attachment list, its folder's
			// count, AND the dashboard folder-browse list (which renders attachments).
			// Mirrors useBatchDeleteAttachments — keep all three keys in sync.
			// 402s (disabled / text-only / too-large / quota) throw LimitExceededError
			// AND open the global UpgradeRequiredDialog via the client's
			// upgradeHandler — nothing to handle here.
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
		},
	});
}

// The vault root has no folder-marker row (the by-id endpoint requires a
// non-null id), so it keys its note list under this sentinel — the same value
// the backend already uses as the batch-move root target. One id-space, one
// shape (`NoteSummary[]`), for every folder including root.
export const ROOT_FOLDER_ID = "root";

// Single fetcher behind every id-keyed note list. Root reads the path-keyed
// list endpoint (the only one that accepts an empty folder); every other
// folder reads its by-id endpoint. Both normalize to `NoteSummary[]`.
export function fetchNotesForFolderId(folderId: string): Promise<NoteSummary[]> {
	if (folderId === ROOT_FOLDER_ID) {
		return api.get<{ notes: NoteSummary[] }>("/folders/list?folder=").then((r) => r.notes);
	}
	// Derived/synthesized folders have no backend marker row, so the by-id endpoint
	// can't resolve them. They carry a `syn:<path>` id — list their notes by path
	// through the same endpoint root uses.
	if (isSyntheticFolderId(folderId)) {
		const path = syntheticFolderPath(folderId);
		return api
			.get<{ notes: NoteSummary[] }>(`/folders/list?folder=${encodeURIComponent(path)}`)
			.then((r) => r.notes);
	}
	return api.get<{ notes: NoteSummary[] }>(`/folders/by-id/${folderId}/notes`).then((r) => r.notes);
}

export function useFolderNotesById(folderId: string | null, opts: { enabled?: boolean } = {}) {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["folder-notes-by-id", vaultId, folderId],
		queryFn: () => fetchNotesForFolderId(folderId as string),
		enabled: folderId != null && (opts.enabled ?? true),
		staleTime: FOLDER_NOTES_STALE_MS,
	});
}

// Resolve a folder PATH (a NoteSummary.folder, or '' for the vault root) to the
// id its note list is cached under. Root maps to the sentinel without a lookup;
// every other folder resolves through the folders cache marker. Returns null
// when an unknown non-root folder isn't in the cache yet — callers skip the
// optimistic patch and let the list surface on its next fetch.
function folderIdForPath(
	qc: QueryClient,
	vaultId: string | null | undefined,
	folder: string,
): string | null {
	if (folder === "") return ROOT_FOLDER_ID;
	return (
		qc
			.getQueryData<{ folders: Folder[] }>(["folders", vaultId])
			?.folders.find((f) => f.name === folder)?.id ?? null
	);
}

export function useNote(id: string | null) {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["note", vaultId, id],
		queryFn: () => fetchNoteById(id as string),
		enabled: id != null,
	});
}

// Single source for the by-id note fetch used by useNote's queryFn.
function fetchNoteById(id: string): Promise<Note> {
	return api.get<Note>(`/notes/by-id/${id}`);
}

export function useUpdateNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation({
		mutationFn: ({ path, content, version }: { path: string; content: string; version?: number }) =>
			api.post<{ note: Note }>("/notes", {
				path,
				content,
				version,
				mtime: Date.now() / 1000,
			}),
		onSuccess: (data) => {
			// The note cache is keyed by id (`['note', vaultId, id]`), not
			// path. Invalidate the specific id when the server returns it,
			// and refresh folder listings so the title/mtime stay current.
			const id = data?.note?.id;
			if (id != null) qc.invalidateQueries({ queryKey: ["note", vaultId, id] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

interface CreateNoteContext {
	key: readonly unknown[];
	snapshot: NoteSummary[];
	placeholderId: string;
}

// Replace the row whose id === `id` in an id-keyed note-list cache. Used to
// swap an optimistic placeholder for the server row. No-op when the list isn't
// cached.
function patchRowInList(
	qc: QueryClient,
	key: readonly unknown[],
	id: string,
	patch: Partial<NoteSummary>,
): void {
	const cur = qc.getQueryData<NoteSummary[]>(key);
	if (cur) {
		qc.setQueryData<NoteSummary[]>(
			key,
			cur.map((n) => (n.id === id ? { ...n, ...patch } : n)),
		);
	}
}

// Filenames in a note list, ignoring our own optimistic placeholders (so a
// freshly-inserted placeholder doesn't bump the name the server picks).
function realFilenames(notes: NoteSummary[]): Set<string> {
	return new Set(
		notes
			.filter((n) => !n.id.startsWith("optimistic-"))
			.map((n) => n.path.split("/").pop() ?? n.path),
	);
}

export function useCreateNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	const navigate = useNavigate();

	return useMutation<
		{ path: string; id: string },
		ApiError,
		{ folder: string },
		CreateNoteContext | undefined
	>({
		mutationFn: async ({ folder }) => {
			const folderId = folderIdForPath(qc, vaultId, folder);
			const existingNotes = folderId
				? (qc.getQueryData<NoteSummary[]>(["folder-notes-by-id", vaultId, folderId]) ?? [])
				: [];
			// Exclude optimistic placeholders so the server name matches the one we
			// showed optimistically (no needless "Untitled 1" bump from our own row).
			const existingNames = realFilenames(existingNotes);

			const MAX_RACES = 5;
			for (let attempt = 0; attempt < MAX_RACES; attempt++) {
				const name = collideBump(existingNames, "Untitled.md", { cap: 1000 });
				const path = folder ? `${folder}/${name}` : name;
				try {
					const { note } = await api.post<{ note: Note }>("/notes", {
						path,
						content: "",
						mtime: Date.now() / 1000,
					});
					return { path, id: note.id };
				} catch (err) {
					if (err instanceof ApiError && err.status === 409) {
						existingNames.add(name);
						continue;
					}
					throw err;
				}
			}
			throw new ApiError(500, "useCreateNote: exceeded race retries");
		},
		// Drop a placeholder row into the id-keyed list the tree reads so a new
		// note shows instantly (on-disk feel), then swap it for the server row on
		// success. Root and subfolders share one cache keyed by folder id.
		onMutate: async ({ folder }) => {
			const folderId = folderIdForPath(qc, vaultId, folder);
			// Unknown non-root folder not in the cache yet — skip; surfaces on expand.
			if (folderId == null) return undefined;
			const key = ["folder-notes-by-id", vaultId, folderId] as const;
			await qc.cancelQueries({ queryKey: key });

			const snapshot = qc.getQueryData<NoteSummary[]>(key);
			// Not cached (e.g. an unexpanded subfolder) — skip; it surfaces on expand.
			if (snapshot === undefined) return undefined;

			const name = collideBump(realFilenames(snapshot), "Untitled.md", { cap: 1000 });
			const path = folder ? `${folder}/${name}` : name;
			const now = new Date().toISOString();
			const placeholderId = `optimistic-${crypto.randomUUID()}`;
			const placeholder: NoteSummary = {
				id: placeholderId,
				path,
				title: name.replace(/\.md$/, ""),
				folder,
				tags: [],
				version: 1,
				mtime: now,
				created_at: now,
				updated_at: now,
			};

			qc.setQueryData<NoteSummary[]>(key, [...snapshot, placeholder]);
			return { key, snapshot, placeholderId };
		},
		onSuccess: ({ id, path }, vars, ctx) => {
			// Swap the placeholder for the server-assigned id/path.
			if (ctx) {
				const filename = path.split("/").pop() ?? path;
				patchRowInList(qc, ctx.key, ctx.placeholderId, {
					id,
					path,
					title: filename.replace(/\.md$/, ""),
				});
				// Only the target folder's list changed — no need to stale the whole
				// prefix (which would force every folder to refetch on next expand).
				qc.invalidateQueries({ queryKey: ctx.key });
			}
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			// Keep the path-keyed list fresh for the dashboard folder-browse view.
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId, vars.folder] });
			navigate(`/note/${id}`);
		},
		onError: (err, _vars, ctx) => {
			if (ctx) qc.setQueryData(ctx.key, ctx.snapshot);
			if (err instanceof ApiError && err.status === 402) {
				toast.error("You've hit your note limit — upgrade to add more.");
			} else if (err instanceof ApiError && err.status === 403) {
				toast.error("You don't have permission to create notes here.");
			} else {
				toast.error("Couldn't create the note. Try again.");
			}
		},
	});
}

export function useCreateFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();

	return useMutation<{ folder: string }, ApiError, { parent: string }>({
		mutationFn: async ({ parent }) => {
			const cached = qc.getQueryData<{ folders: Folder[] }>(["folders", vaultId]);
			const existingFolders = cached?.folders.map((f) => f.name) ?? [];

			// Restrict to direct children of the parent — siblings only.
			const prefix = parent ? `${parent}/` : "";
			const childNames = new Set(
				existingFolders
					.filter((f) => (parent === "" ? !f.includes("/") : f.startsWith(prefix)))
					.map((f) => (parent === "" ? f : f.slice(prefix.length)))
					.map((f) => f.split("/")[0] ?? f),
			);

			const MAX_RACES = 5;
			for (let attempt = 0; attempt < MAX_RACES; attempt++) {
				const name = collideBump(childNames, "Untitled folder", { cap: 1000 });
				const folder = parent ? `${parent}/${name}` : name;
				try {
					await api.post<{ folder: { name: string; count: number } }>("/folders", { folder });
					return { folder };
				} catch (err) {
					if (err instanceof ApiError && err.status === 409) {
						childNames.add(name);
						continue;
					}
					throw err;
				}
			}
			throw new ApiError(500, "useCreateFolder: exceeded race retries");
		},
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
		},
		onError: (err) => {
			if (err instanceof ApiError && err.status === 422) {
				toast.error("That folder name isn't allowed.");
			} else if (err instanceof ApiError && err.status === 403) {
				toast.error("You don't have permission to create folders here.");
			} else {
				toast.error("Couldn't create the folder. Try again.");
			}
		},
	});
}

export function useSearch(query: string) {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["search", vaultId, query],
		// Each search costs a Voyage embedding + Qdrant round trip server-side:
		// abort superseded requests, and keep the previous results rendered
		// while the next key loads so the panel doesn't flicker empty.
		queryFn: ({ signal }) =>
			api.post<{ results: SearchResult[] }>("/search", { query, limit: 20 }, { signal }),
		select: (data) => data.results,
		enabled: query.length > 0,
		placeholderData: keepPreviousData,
	});
}

export function useTags() {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["tags", vaultId],
		queryFn: () => api.get<{ tags: string[] }>("/tags"),
		select: (data) => data.tags,
	});
}

export function useMe() {
	return useQuery({
		queryKey: ["me"],
		queryFn: () => api.get<{ user: User }>("/me"),
		select: (data) => data.user,
	});
}

export function useUpdateProfile() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (body: { display_name: string | null }) => api.patch<{ user: User }>("/me", body),
		onSuccess: (data) => {
			qc.setQueryData(["me"], data);
		},
	});
}

export function useDeleteSelf() {
	return useMutation<void, Error, { password: string }>({
		mutationFn: async ({ password }) => {
			await api.del<void>(`/me?password=${encodeURIComponent(password)}`);
		},
	});
}

// Billing types
export interface BillingStatus {
	tier: "free" | "none" | "trial" | "starter" | "pro";
	active: boolean;
	trial_days_remaining: number;
	subscription: {
		status: string;
		tier: string;
		current_period_end: string;
	} | null;
	caps: {
		obsidian_connections: number | null;
		mcp_connections: number | null;
		api_write_enabled: boolean;
		vaults: number | null;
	};
	// Bundled into /billing/status so the proactive cap UI (on /link and
	// /oauth/consent) can decide atCap from a single fetch — no separate
	// /connections call just to count.
	current_connections: {
		obsidian: number;
		mcp: number;
	};
	// Hours remaining on the Free-tier device-swap cooldown after a recent
	// device revoke; `null` when no cooldown is in effect. Lets /link render
	// a cooldown banner + disable Authorize BEFORE the user trips the 402.
	device_swap_cooldown_remaining_hours: number | null;
}

// Billing hooks

export function useBillingStatus() {
	return useQuery({
		queryKey: ["billing", "status"],
		queryFn: () => api.get<BillingStatus>("/billing/status"),
		// Seeded fresh by useAppBootstrap on first load; mutations that change
		// billing invalidate this key explicitly, so a short staleTime just
		// suppresses a redundant refetch-on-mount of the seeded payload.
		staleTime: 60_000,
	});
}

export interface BillingConfig {
	client_token: string;
	environment: "sandbox" | "production";
	price_ids: {
		starter: { monthly: string; annual: string };
		pro: { monthly: string; annual: string };
	};
	customer_email: string;
	custom_data: {
		user_id: string;
	};
	// Maximum number of active vaults the user may have, or null for unlimited.
	vaults_cap: number | null;
}

export type BillingCadence = "monthly" | "annual";

export function useBillingConfig() {
	return useQuery({
		queryKey: ["billing", "config"],
		queryFn: () => api.get<BillingConfig>("/billing/config"),
		staleTime: Infinity,
	});
}

export interface SubscriptionDetail {
	next_billed_at: string | null;
	amount: string | null;
	currency: string | null;
	billing_cycle: { interval: string; frequency: number } | null;
	scheduled_change: { action: string; effective_at: string } | null;
}

export interface PaymentMethod {
	type: string | null;
	card_brand: string | null;
	last4: string | null;
	exp_month: number | null;
	exp_year: number | null;
}

export interface BillingTransaction {
	id: string;
	billed_at: string | null;
	amount: string | null;
	currency: string | null;
	status: string;
	invoice_id: string | null;
}

export interface BillingHistory {
	payment_method: PaymentMethod | null;
	transactions: BillingTransaction[];
}

// Live read-through endpoints — only meaningful for users with a Paddle
// subscription (they 404 otherwise), so callers gate with `enabled`.
export function useBillingSubscriptionDetail(enabled: boolean) {
	return useQuery({
		queryKey: ["billing", "subscription"],
		queryFn: () => api.get<SubscriptionDetail>("/billing/subscription"),
		enabled,
	});
}

export function useBillingHistory(enabled: boolean) {
	return useQuery({
		queryKey: ["billing", "transactions"],
		queryFn: () => api.get<BillingHistory>("/billing/transactions"),
		enabled,
	});
}

// Onboarding types

export type OnboardingAction =
	| "tour_offered_taken"
	| "tour_offered_skipped"
	| "tour_completed"
	| "first_vault_created"
	| "plugin_connected"
	| "ai_connected"
	| `dismissed:${string}`;

export interface OnboardingStatus {
	enabled: boolean;
	terms_ok?: boolean;
	subscription_ok?: boolean;
	profile_complete?: boolean;
	// Echoed back once `set_profile/2` has run — drives the personalized
	// setup cards on the dashboard. Absent until the questionnaire is done.
	profile?: OnboardingProfile;
	// True when at least one non-deleted vault exists. The fresh-start
	// onboarding path (uses_obsidian=false) gates `next_step: "vault"` on
	// this; Obsidian users short-circuit past the gate (plugin creates the
	// vault on first OAuth sign-in).
	has_vault?: boolean;
	current_tos_version?: string;
	current_privacy_version?: string;
	next_step: OnboardingStep | "done";
	// Full intended step chain for THIS account at this moment. Self-host
	// returns ["tools","vault"]; hosted returns ["agreement","billing",
	// "tools","vault"]. `:tools` collects the FTUX tool checkboxes; `:vault`
	// owns the obsidian/fresh source pick + first-vault creation. The
	// frontend uses this for "Step X of N" and to reject manual nav to a
	// step not in the chain (e.g. /onboard/agreement on self-host).
	steps: OnboardingStep[];
	// Post-wizard milestone log driving the persistent dashboard checklist.
	actions: OnboardingAction[];
	// Live vault count for checklist gating + tour decisions.
	vault_count: number;
}

export type OnboardingStep = "agreement" | "billing" | "tools" | "vault";

// Partial mid-flow: the `:tools` step POSTs `tools` first, the `:vault`
// step POSTs `uses_obsidian` after. `completed_at` only stamps once both
// have landed — until then, treat absent fields as "user hasn't answered
// that screen yet."
export interface OnboardingProfile {
	uses_obsidian?: boolean;
	tools?: string[];
	completed_at?: string;
}

// Onboarding hooks

export function useOnboardingStatus() {
	return useQuery({
		queryKey: ["onboarding", "status"],
		queryFn: () => api.get<OnboardingStatus>("/onboarding/status"),
		staleTime: Infinity,
		refetchOnWindowFocus: true,
	});
}

export function useRecordOnboardingAction() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (action: OnboardingAction) =>
			api.post<{ status: string }>("/onboarding/actions", { action }),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["onboarding", "status"] }),
		retry: 3,
	});
}

// ── Bootstrap ──────────────────────────────────────────────────────────────
//
// One round-trip on first load that returns onboarding + capabilities + vaults
// (+ billing when enabled), replacing the serial onboarding/billing/vaults
// fan-out the app used to make before becoming usable. See
// docs/context/spa-state-injection.md for why this is a fetch (the SaaS HTML is
// served by Cloudflare and can't inject per-user post-auth state at first paint).

// Resolved entitlement matrix. Every LimitKeys key: an integer cap, a boolean
// feature flag, or null (no cap / unlimited). Advisory for UX gating — the
// server still enforces every limit authoritatively.
export interface Capabilities {
	tier: "free" | "starter" | "pro";
	limits: Record<string, number | boolean | null>;
}

export interface BootstrapPayload {
	onboarding: OnboardingStatus;
	capabilities: Capabilities;
	vaults: { vaults: Vault[] };
	// Present only when billing is enabled (SaaS); absent on self-host.
	billing?: BillingStatus;
}

export function useCapabilities() {
	return useQuery({
		queryKey: ["capabilities"],
		// Normally read straight from the cache seeded by useAppBootstrap (staleTime
		// Infinity → no fetch). The queryFn is a fallback for any consumer that
		// mounts before the gate's bootstrap seed lands.
		queryFn: () => api.get<BootstrapPayload>("/bootstrap").then((b) => b.capabilities),
		staleTime: Infinity,
	});
}

/**
 * Fetches the consolidated first-load payload and seeds the granular query
 * caches (onboarding, billing, vaults, capabilities) so the hooks that read
 * those keys resolve from cache instead of issuing their own requests. Mount
 * this at the top of the authenticated tree (the onboarding gate) so the seed
 * lands before any vault-scoped view mounts.
 */
export function useAppBootstrap() {
	const qc = useQueryClient();
	return useQuery({
		queryKey: ["bootstrap"],
		queryFn: async () => {
			const data = await api.get<BootstrapPayload>("/bootstrap");
			qc.setQueryData(["onboarding", "status"], data.onboarding);
			qc.setQueryData(["capabilities"], data.capabilities);
			qc.setQueryData(["vaults"], data.vaults);
			if (data.billing) qc.setQueryData(["billing", "status"], data.billing);
			return data;
		},
		staleTime: Infinity,
	});
}

export function useAcceptTerms() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (body: {
			tos_version: string;
			tos_hash: string;
			privacy_version: string;
			privacy_hash: string;
		}) => api.post<{ version: string; accepted_at: string }>("/onboarding/accept-terms", body),
		// `await` is load-bearing: callers (agreement-page) navigate to /onboard
		// immediately after the mutation resolves, and OnboardRedirect reads cached
		// status to pick the next step. Without awaiting the refetch, the stale
		// `next_step: 'agreement'` bounces the user back to the same page and
		// they're forced to accept twice. invalidateQueries returns a Promise that
		// settles when active queries have refetched — await it.
		onSuccess: async () => {
			await qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		},
	});
}

// Partial body — the `:tools` screen POSTs `{ tools }`, the `:vault` screen
// POSTs `{ uses_obsidian }`. Either field may be present (or both, on a
// one-shot completion). Backend `set_profile/2` merges into the JSONB
// column and stamps `completed_at` once both halves have landed.
export function useSetOnboardingProfile() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (body: { uses_obsidian?: boolean; tools?: string[] }) =>
			api.patch<OnboardingProfile>("/onboarding/profile", body),
		// AWAIT the invalidation so mutateAsync resolves only after
		// ['onboarding','status'] has refetched. Without the await,
		// OnboardingGate reads the still-cached next_step (e.g. "tools")
		// immediately after navigate and bounces back here.
		onSuccess: async () => {
			await qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		},
	});
}

// API key result shape — created by useCreatePat below; kept as a named
// type because the reveal modal in settings/connections-page.tsx imports it.

export interface CreatedApiKey {
	id: string;
	name: string;
	key: string;
}

// ── Connections ─────────────────────────────────────────────

export type ConnectionKind = "obsidian" | "mcp" | "pat";

export interface Connection {
	kind: ConnectionKind;
	client_id: string | null;
	key_id: string | null;
	name: string | null;
	software_id: string | null;
	software_version: string | null;
	verified: boolean;
	logo: string | null;
	slug: string | null;
	vault_id: string | null;
	vault_name: string | null;
	scope: string | null;
	last_used_at: string | null;
	connected_at: string | null;
	first_user_agent: string | null;
	first_ip: string | null;
	redirect_uris: string[];
}

export interface CapErrorBody {
	error: "connection_cap_reached";
	kind: "obsidian" | "mcp";
	current: number;
	limit: number;
	upgrade_url: string;
}

export interface PatDisabledErrorBody {
	error: "pat_disabled_on_free";
	upgrade_url: string;
}

export function useConnections(opts?: { enabled?: boolean }) {
	return useQuery({
		queryKey: ["connections"],
		queryFn: () => api.get<Connection[]>("/connections"),
		enabled: opts?.enabled ?? true,
	});
}

export function useCreatePat() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (name: string) =>
			api.post<{ key: string; id: string; name: string }>("/connections/pat", { name }),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["connections"] });
		},
	});
}

export function useRevokeOauthConnection() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (clientId: string) => api.del(`/connections/oauth/${clientId}`),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["connections"] }),
	});
}

export function useRevokeDeviceConnection() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (familyId: string) => api.del(`/connections/device/${familyId}`),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["connections"] }),
	});
}

export function useRevokePat() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.del(`/connections/pat/${id}`),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["connections"] });
		},
	});
}

// Vault types (encryption fields are the ones we care about for settings)

export type EncryptionStatus = "none" | "encrypting" | "encrypted" | "decrypt_pending";

export interface Vault {
	id: string;
	name: string;
	description: string | null;
	slug: string;
	is_default: boolean;
	created_at: string;
	encrypted: boolean;
	encryption_status: EncryptionStatus;
	encrypted_at: string | null;
	decrypt_requested_at: string | null;
	last_toggle_at: string | null;
	cooldown_days: number | null;
	deleted_at?: string | null;
	purge_at?: string | null;
	note_count?: number;
	attachment_count?: number;
}

export interface EncryptionProgress {
	processed: number;
	total: number;
	status: EncryptionStatus;
	started_at: string | null;
}

// Vault hooks

export function useVaults() {
	const demo = useDemoVaultOptional();
	const query = useQuery({
		queryKey: ["vaults"],
		queryFn: () => api.get<{ vaults: Vault[] }>("/vaults"),
		select: (data) => data.vaults,
		enabled: !demo?.active,
		// Seeded fresh by useAppBootstrap on first load; vault mutations invalidate
		// this key explicitly, so a short staleTime just suppresses the redundant
		// refetch-on-mount of the seeded list.
		staleTime: 60_000,
	});
	if (demo?.active && demo.vault) {
		const base = {
			description: null,
			created_at: new Date(0).toISOString(),
			encrypted: false,
			encryption_status: "none" as const,
			encrypted_at: null,
			decrypt_requested_at: null,
			last_toggle_at: null,
			cooldown_days: null,
			note_count: demo.notes.length,
		};
		// Two fake vaults so the VaultSwitcher renders its dropdown — the tour's
		// first step is gated on a real switch between them. Notes are shared.
		const vaults: Vault[] = [
			{ ...base, id: "demo-vault-1", name: demo.vault.name, slug: demo.vault.id, is_default: true },
			{
				...base,
				id: "demo-vault-2",
				name: "Personal",
				slug: `${demo.vault.id}-personal`,
				is_default: false,
			},
		];
		return {
			...query,
			data: vaults,
			isLoading: false,
			isPending: false,
			error: null,
		} as typeof query;
	}
	return query;
}

export function useEncryptVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.post<{ vault: Vault }>(`/vaults/${id}/encrypt`),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["vaults"] });
			qc.invalidateQueries({ queryKey: ["encryption-progress"] });
		},
	});
}

export function useEncryptionProgress(vaultId: string | undefined, enabled: boolean) {
	return useQuery({
		queryKey: ["encryption-progress", vaultId],
		queryFn: () => api.get<EncryptionProgress>(`/vaults/${vaultId}/encryption_progress`),
		enabled: enabled && vaultId !== undefined,
		refetchInterval: enabled ? 3000 : false,
	});
}

export function useDeletedVaults() {
	return useQuery({
		queryKey: ["vaults", "deleted"],
		queryFn: () => api.get<{ vaults: Vault[] }>("/vaults?deleted=true"),
		select: (data) => data.vaults,
	});
}

export function useDeleteVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.del<{ deleted: boolean }>(`/vaults/${id}`),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["vaults"] }),
	});
}

export function useRestoreVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.post<{ vault: Vault }>(`/vaults/${id}/restore`),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["vaults"] }),
	});
}

export function usePurgeVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.post<{ purged: boolean }>(`/vaults/${id}/purge`),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["vaults"] }),
	});
}

export function useUpdateVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: ({
			id,
			...attrs
		}: {
			id: string;
			name?: string;
			description?: string;
			is_default?: boolean;
		}) => api.patch<{ vault: Vault }>(`/vaults/${id}`, attrs),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["vaults"] }),
	});
}

export function useCreateVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (attrs: { name: string; description?: string }) =>
			api.post<{ vault: Vault }>("/vaults", attrs),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["vaults"] });
			// Backend records `first_vault_created` in Vaults.create_vault/2;
			// refresh /status so the onboarding checklist ticks immediately.
			qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		},
	});
}

// Inline billing mutations replacing the portal redirect — each invalidates
// /billing/status + /billing/subscription so the StatusCard reflects the
// new scheduled change immediately, before webhook sync catches up.

/**
 * Invalidate every cache derived from the user's subscription state — the
 * volatile billing slices AND the cached capability matrix (`['capabilities']`,
 * the tier+limits map seeded by bootstrap). Call after ANY subscription change
 * (checkout completed, activation push, plan change, cancel, reverse-cancel) so
 * the tier badge, caps, plan-change "current" highlight, and free-tier gates
 * all refresh together. Missing one key here is how an upgrade leaves the UI
 * stuck on the old tier until a manual refresh (#603). Returns a promise so
 * callers that need fresh data before navigating can await it.
 */
export function invalidateBillingState(qc: QueryClient) {
	return Promise.all([
		qc.invalidateQueries({ queryKey: ["billing", "status"] }),
		qc.invalidateQueries({ queryKey: ["billing", "subscription"] }),
		qc.invalidateQueries({ queryKey: ["billing", "transactions"] }),
		qc.invalidateQueries({ queryKey: ["capabilities"] }),
	]);
}

export function useCancelSubscription() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: () => api.post<Record<string, unknown>>("/billing/cancel-subscription"),
		onSuccess: () => invalidateBillingState(qc),
	});
}

export function useReverseCancel() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: () => api.post<Record<string, unknown>>("/billing/reverse-cancel"),
		onSuccess: () => invalidateBillingState(qc),
	});
}

export interface PlanChangePreview {
	old_total: number;
	new_total: number;
	immediate_charge_or_credit: number;
	next_billed_at: string;
}

export function usePlanChangePreview(targetPriceId: string | null) {
	return useQuery({
		queryKey: ["billing", "plan-change", "preview", targetPriceId],
		enabled: targetPriceId !== null,
		queryFn: () =>
			api.post<PlanChangePreview>("/billing/plan-change/preview", {
				target_price_id: targetPriceId,
			}),
		// Preview hits Paddle. Without these, every window focus/refocus
		// (alt-tab back to the picker tab) re-POSTs to Paddle. The data
		// is stable for the lifetime of the picker session — proration
		// math only changes when the user picks a different target or
		// a webhook flips their subscription (both invalidate the key).
		staleTime: 5 * 60_000,
		refetchOnWindowFocus: false,
	});
}

export function useConfirmPlanChange() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (targetPriceId: string) =>
			api.post<Record<string, unknown>>("/billing/plan-change/confirm", {
				target_price_id: targetPriceId,
			}),
		onSuccess: () => invalidateBillingState(qc),
	});
}

// ── Tree mutations (rename / delete / duplicate) ─────────────
//
// Folder/note rename + delete on the tree. Rename endpoints return 409
// on target-exists (collision) and 404 if the source is missing — both
// surface as ApiError to the caller via api.post / api.del.
//
// Each mutation runs optimistically: `onMutate` snapshots the affected
// caches, applies the change locally so the UI updates synchronously,
// and stashes the snapshot in the mutation context. `onError` restores
// the snapshot and toasts the failure. `onSettled` invalidates the
// affected query families so the server stays the source of truth and
// out-of-band changes (Phoenix channel push, other-tab edits) get
// reconciled.

// Path → parent folder. `'a/b/c.md'` → `'a/b'`; `'a.md'` → `''`. Same
// rule the backend uses when computing `folder` on a NoteSummary.
function folderOf(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
}

// Apply `mut` to the entry at `key` only if it is currently cached.
// Skipping uncached keys keeps optimistic edits cheap and avoids
// pre-seeding caches that would otherwise refetch lazily on mount.
function updateCachedList<T>(
	qc: QueryClient,
	key: readonly unknown[],
	mut: (data: { notes: T[] }) => { notes: T[] },
) {
	const prev = qc.getQueryData<{ notes: T[] }>(key as readonly unknown[]);
	if (!prev) return;
	qc.setQueryData(key as readonly unknown[], mut(prev));
}

// 409/404/etc → human-grade toast copy. Centralised so all four
// mutations (and the standalone drop handler) speak the same dialect.
function renameErrorToast(err: ApiError, kind: "file" | "folder") {
	const noun = kind === "file" ? "note" : "folder";
	if (err.status === 409) toast.error(`A ${noun} with that name already exists.`);
	else if (err.status === 404)
		toast.error(`${noun[0]?.toUpperCase()}${noun.slice(1)} no longer exists.`);
	else toast.error("Rename failed.");
}

function deleteErrorToast(err: ApiError, kind: "file" | "folder") {
	const noun = kind === "file" ? "Note" : "Folder";
	if (err.status === 404) toast.error(`${noun} no longer exists.`);
	else toast.error("Delete failed.");
}

interface RenameNoteContext {
	oldFolder: string;
	newFolder: string;
	oldFolderNotes: { notes: NoteSummary[] } | undefined;
	newFolderNotes: { notes: NoteSummary[] } | undefined;
	folders: { folders: Folder[] } | undefined;
	// The note id is stable across rename — only `path`/`folder` shift.
	// We snapshot the previous note value so rollback restores those
	// fields under the SAME cache key.
	noteId: string | null;
	prevNote: Note | undefined;
}

export function useRenameNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ renamed: boolean; old_path: string; new_path: string; note: Note },
		ApiError,
		{ old_path: string; new_path: string },
		RenameNoteContext
	>({
		mutationFn: (vars) =>
			api.post<{ renamed: boolean; old_path: string; new_path: string; note: Note }>(
				"/notes/rename",
				vars,
			),
		onMutate: async ({ old_path, new_path }) => {
			const oldFolder = folderOf(old_path);
			const newFolder = folderOf(new_path);
			const oldListKey = ["folderNotes", vaultId, oldFolder] as const;
			const newListKey = ["folderNotes", vaultId, newFolder] as const;
			const foldersKey = ["folders", vaultId] as const;

			// Stop in-flight queries from clobbering the optimistic write.
			await qc.cancelQueries({ queryKey: ["folderNotes", vaultId] });
			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: ["note", vaultId] });

			const oldFolderNotes = qc.getQueryData<{ notes: NoteSummary[] }>(oldListKey);
			const newFolderNotes = qc.getQueryData<{ notes: NoteSummary[] }>(newListKey);
			const folders = qc.getQueryData<{ folders: Folder[] }>(foldersKey);

			// Resolve the note id from whatever cache has it. The folder
			// list is the cheapest lookup; failing that, walk every cached
			// `['note', vaultId, *]` entry looking for the matching path.
			const fromList = oldFolderNotes?.notes.find((n) => n.path === old_path);
			let noteId: string | null = fromList?.id ?? null;
			let prevNote: Note | undefined;
			if (noteId == null) {
				const cached = qc
					.getQueryCache()
					.findAll({ queryKey: ["note", vaultId] })
					.map((q) => q.state.data as Note | undefined)
					.find((n) => n?.path === old_path);
				if (cached) {
					noteId = cached.id;
					prevNote = cached;
				}
			} else {
				prevNote = qc.getQueryData<Note>(["note", vaultId, noteId]);
			}

			const ctx: RenameNoteContext = {
				oldFolder,
				newFolder,
				oldFolderNotes,
				newFolderNotes,
				folders,
				noteId,
				prevNote,
			};

			// Build a renamed NoteSummary either from the existing list row
			// or from the cached note body so the new folder list still gets
			// a visible entry even when the old list isn't cached.
			const renamedSummary: NoteSummary | null = fromList
				? { ...fromList, path: new_path, folder: newFolder }
				: prevNote
					? {
							id: prevNote.id,
							path: new_path,
							title: prevNote.title,
							folder: newFolder,
							tags: prevNote.tags,
							version: prevNote.version,
							mtime: prevNote.mtime,
							created_at: prevNote.created_at,
							updated_at: prevNote.updated_at,
						}
					: null;

			// Remove from old list (by id when we have it, by path otherwise).
			if (oldFolderNotes) {
				updateCachedList<NoteSummary>(qc, oldListKey, (prev) => ({
					notes: prev.notes.filter((n) => (noteId != null ? n.id !== noteId : n.path !== old_path)),
				}));
			}

			// Drop a renamed copy into the new folder list (if cached).
			if (renamedSummary && newFolderNotes) {
				updateCachedList<NoteSummary>(qc, newListKey, (prev) => ({
					notes: [
						...prev.notes.filter((n) => (noteId != null ? n.id !== noteId : n.path !== new_path)),
						renamedSummary,
					],
				}));
			}

			// Adjust folder counts when the note crosses folder boundaries.
			if (oldFolder !== newFolder && folders) {
				qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) => {
					if (!prev) return prev;
					let next = prev.folders.map((f) =>
						f.name === oldFolder ? { ...f, count: Math.max(0, f.count - 1) } : f,
					);
					const hasNewEntry = next.some((f) => f.name === newFolder);
					if (hasNewEntry) {
						next = next.map((f) => (f.name === newFolder ? { ...f, count: f.count + 1 } : f));
					} else if (newFolder !== "") {
						// Optimistic placeholder — real backend id + parent_id land
						// when `onSettled` refetches the folders list. The `optimistic-`
						// sentinel id won't collide with real uuids; the null parent_id
						// is benign because the refetch reconciles before any consumer
						// can rely on tree shape here.
						next = [
							...next,
							{
								id: `optimistic-${crypto.randomUUID()}`,
								parent_id: null,
								name: newFolder,
								count: 1,
							},
						];
					} else {
						// Root files don't get a synthetic '' entry — folders() filters
						// those out anyway; the note shows up via RootFiles.
					}
					return { folders: next };
				});
			}

			// The note id is stable across rename — only `path` and `folder`
			// change. Update those fields in place under the SAME cache key
			// (`['note', vaultId, id]`). No key shuffle: any subscriber to
			// useNote(id) sees the new fields without remounting.
			if (noteId != null && prevNote) {
				qc.setQueryData<Note>(["note", vaultId, noteId], {
					...prevNote,
					path: new_path,
					folder: newFolder,
				});
			}

			return ctx;
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) return;
			const oldListKey = ["folderNotes", vaultId, ctx.oldFolder];
			const newListKey = ["folderNotes", vaultId, ctx.newFolder];
			const foldersKey = ["folders", vaultId];
			if (ctx.oldFolderNotes !== undefined) qc.setQueryData(oldListKey, ctx.oldFolderNotes);
			if (ctx.newFolderNotes !== undefined) qc.setQueryData(newListKey, ctx.newFolderNotes);
			if (ctx.folders !== undefined) qc.setQueryData(foldersKey, ctx.folders);
			if (ctx.noteId != null && ctx.prevNote !== undefined) {
				qc.setQueryData(["note", vaultId, ctx.noteId], ctx.prevNote);
			}
			renameErrorToast(err, "file");
		},
		onSettled: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

interface RenameFolderContext {
	folders: { folders: Folder[] } | undefined;
	// Snapshot of every cached folderNotes entry we touched, keyed by the
	// joined query key. Folder rename is coarse (see below) — we DROP all
	// child folderNotes entries to force refetch on next expand, which
	// means rollback needs to restore them.
	childLists: Array<{ key: readonly unknown[]; data: { notes: NoteSummary[] } | undefined }>;
	// Notes cached by id whose `folder` was under the old prefix. We
	// rewrite path/folder in place under the same key (id is stable);
	// snapshots capture the pre-rename value for rollback.
	noteSnapshots: Array<{ id: string; note: Note }>;
}

export function useRenameFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ renamed: boolean; old_path: string; new_path: string; count: number },
		ApiError,
		{ old_path: string; new_path: string },
		RenameFolderContext
	>({
		mutationFn: (vars) =>
			api.post<{
				renamed: boolean;
				old_path: string;
				new_path: string;
				count: number;
			}>("/folders/rename", vars),
		onMutate: async ({ old_path, new_path }) => {
			// COARSE optimistic strategy: rewrite folder names in ['folders']
			// (the renamed folder + every descendant) and DROP every cached
			// folderNotes entry under the old prefix. Note paths inside those
			// lists would need full prefix-rewrite to stay coherent, and the
			// user almost certainly isn't looking at every descendant list at
			// once — refetching on next expand is cheap and exact. The list
			// for the renamed folder ITSELF gets the same treatment.
			const foldersKey = ["folders", vaultId] as const;
			await qc.cancelQueries({ queryKey: ["folderNotes", vaultId] });
			await qc.cancelQueries({ queryKey: foldersKey });

			await qc.cancelQueries({ queryKey: ["note", vaultId] });

			const ctx: RenameFolderContext = {
				folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
				childLists: [],
				noteSnapshots: [],
			};

			// Rewrite folder names.
			if (ctx.folders) {
				qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) => {
					if (!prev) return prev;
					const oldPrefix = `${old_path}/`;
					return {
						folders: prev.folders.map((f) => {
							if (f.name === old_path) return { ...f, name: new_path };
							if (f.name.startsWith(oldPrefix)) {
								return { ...f, name: `${new_path}/${f.name.slice(oldPrefix.length)}` };
							}
							return f;
						}),
					};
				});
			}

			// Snapshot + drop every cached folderNotes entry under the old prefix.
			const all = qc.getQueryCache().findAll({ queryKey: ["folderNotes", vaultId] });
			for (const q of all) {
				const folder = q.queryKey[2] as string | undefined;
				if (typeof folder !== "string") continue;
				if (folder !== old_path && !folder.startsWith(`${old_path}/`)) continue;
				ctx.childLists.push({
					key: q.queryKey,
					data: qc.getQueryData<{ notes: NoteSummary[] }>(q.queryKey),
				});
				qc.removeQueries({ queryKey: q.queryKey });
			}

			// Rewrite every cached `['note', vaultId, id]` whose folder sits
			// under the old prefix. The id is stable across folder rename —
			// path + folder shift, key stays put. This keeps any open
			// useNote(id) subscriber coherent without a remount.
			const oldPrefix = `${old_path}/`;
			const allNotes = qc.getQueryCache().findAll({ queryKey: ["note", vaultId] });
			for (const q of allNotes) {
				const note = q.state.data as Note | undefined;
				if (!note) continue;
				if (note.folder !== old_path && !note.folder.startsWith(oldPrefix)) continue;
				ctx.noteSnapshots.push({ id: note.id, note });
				const suffixFolder = note.folder === old_path ? "" : note.folder.slice(oldPrefix.length);
				const newFolder = suffixFolder ? `${new_path}/${suffixFolder}` : new_path;
				// The note path always starts with `${old_path}/` (a note can't
				// live AT a folder key), so strip + reattach.
				const newPath = `${new_path}/${note.path.slice(oldPrefix.length)}`;
				qc.setQueryData<Note>(["note", vaultId, note.id], {
					...note,
					path: newPath,
					folder: newFolder,
				});
			}

			return ctx;
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) return;
			if (ctx.folders !== undefined) qc.setQueryData(["folders", vaultId], ctx.folders);
			for (const entry of ctx.childLists) {
				if (entry.data !== undefined) qc.setQueryData(entry.key, entry.data);
			}
			for (const snap of ctx.noteSnapshots) {
				qc.setQueryData<Note>(["note", vaultId, snap.id], snap.note);
			}
			renameErrorToast(err, "folder");
		},
		onSettled: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

interface DeleteNoteContext {
	folder: string;
	id: string;
	folderNotes: { notes: NoteSummary[] } | undefined;
	folders: { folders: Folder[] } | undefined;
	note: Note | undefined;
}

// `path` rides along so optimistic onMutate can locate the row in the
// folderNotes cache + adjust the parent folder's count without a round
// trip. The URL itself only needs the id.
export function useDeleteNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ deleted: boolean } | void,
		ApiError,
		{ id: string; path: string },
		DeleteNoteContext
	>({
		mutationFn: ({ id }) => api.del<{ deleted: boolean }>(`/notes/by-id/${id}`),
		onMutate: async ({ id, path }) => {
			const folder = folderOf(path);
			const listKey = ["folderNotes", vaultId, folder] as const;
			const foldersKey = ["folders", vaultId] as const;
			const noteKey = ["note", vaultId, id] as const;

			await qc.cancelQueries({ queryKey: ["folderNotes", vaultId] });
			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: noteKey });

			const ctx: DeleteNoteContext = {
				folder,
				id,
				folderNotes: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
				folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
				note: qc.getQueryData<Note>(noteKey),
			};

			if (ctx.folderNotes) {
				updateCachedList<NoteSummary>(qc, listKey, (prev) => ({
					notes: prev.notes.filter((n) => n.id !== id),
				}));
			}
			if (ctx.folders) {
				qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) =>
					prev
						? {
								folders: prev.folders.map((f) =>
									f.name === folder ? { ...f, count: Math.max(0, f.count - 1) } : f,
								),
							}
						: prev,
				);
			}
			qc.removeQueries({ queryKey: noteKey });
			return ctx;
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) return;
			const listKey = ["folderNotes", vaultId, ctx.folder];
			const foldersKey = ["folders", vaultId];
			const noteKey = ["note", vaultId, ctx.id];
			if (ctx.folderNotes !== undefined) qc.setQueryData(listKey, ctx.folderNotes);
			if (ctx.folders !== undefined) qc.setQueryData(foldersKey, ctx.folders);
			if (ctx.note !== undefined) qc.setQueryData(noteKey, ctx.note);
			deleteErrorToast(err, "file");
		},
		onSettled: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

interface DeleteFolderContext {
	folders: { folders: Folder[] } | undefined;
	folderList: { notes: NoteSummary[] } | undefined;
}

export function useDeleteFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: boolean } | void, ApiError, { path: string }, DeleteFolderContext>({
		mutationFn: ({ path }) => api.del<{ deleted: boolean }>(`/folders/${encodePathSegments(path)}`),
		onMutate: async ({ path }) => {
			// Coarse: drop the folder entry + its own folderNotes cache. We
			// don't chase descendant folderNotes entries — the user will
			// refetch them next time they expand the (now nonexistent) child.
			const foldersKey = ["folders", vaultId] as const;
			const listKey = ["folderNotes", vaultId, path] as const;

			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: listKey });

			const ctx: DeleteFolderContext = {
				folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
				folderList: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
			};

			if (ctx.folders) {
				qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) =>
					prev
						? {
								folders: prev.folders.filter(
									(f) => f.name !== path && !f.name.startsWith(`${path}/`),
								),
							}
						: prev,
				);
			}
			qc.removeQueries({ queryKey: listKey });
			return ctx;
		},
		onError: (err, vars, ctx) => {
			if (!ctx) return;
			if (ctx.folders !== undefined) qc.setQueryData(["folders", vaultId], ctx.folders);
			if (ctx.folderList !== undefined)
				qc.setQueryData(["folderNotes", vaultId, vars.path], ctx.folderList);
			deleteErrorToast(err, "folder");
		},
		onSettled: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

// Duplicate a note: read source content, then write a fresh note at a
// caller-chosen `new_path`. The collision-free name is computed by the
// caller (see `viewer/tree-actions/duplicate.ts#nextCopyName`) — keeping
// this mutation a thin GET-then-POST means tests don't need to reason
// about siblings, and the name policy stays in one place.
//
// Optimistic strategy: drop a placeholder NoteSummary into the new
// folder's list immediately so the row appears in the tree. The GET+POST
// happens in the background; on success the placeholder is replaced
// (via onSettled refetch); on error the placeholder is pulled.

interface DuplicateNoteContext {
	placeholderId: string;
	// The id-keyed list the tree reads (set only when the target folder's list
	// is cached), plus its snapshot for rollback.
	key?: readonly unknown[];
	snapshot?: NoteSummary[];
}

export function useDuplicateNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ note: Note },
		ApiError,
		{ src_path: string; new_path: string },
		DuplicateNoteContext
	>({
		mutationFn: async ({ src_path, new_path }) => {
			const src = await api.get<Note>(`/notes/${encodePathSegments(src_path)}`);
			return api.post<{ note: Note }>("/notes", {
				path: new_path,
				content: src.content ?? "",
				mtime: Date.now() / 1000,
			});
		},
		onMutate: async ({ src_path, new_path }) => {
			const newFolder = folderOf(new_path);
			const targetId = folderIdForPath(qc, vaultId, newFolder);

			// Placeholder id — the real one arrives with the POST response.
			// `optimistic-` prefix avoids collisions with real backend uuids;
			// onSuccess swaps it for the server-assigned id in the cached list.
			const placeholderId = `optimistic-${crypto.randomUUID()}`;
			const ctx: DuplicateNoteContext = { placeholderId };

			// Seed metadata from the source row if we have it cached — gives
			// the placeholder a usable title/tags so the row looks real.
			const srcId = folderIdForPath(qc, vaultId, folderOf(src_path));
			const srcRow = srcId
				? qc
						.getQueryData<NoteSummary[]>(["folder-notes-by-id", vaultId, srcId])
						?.find((n) => n.path === src_path)
				: undefined;
			const now = new Date().toISOString();
			const placeholder: NoteSummary = {
				id: placeholderId,
				path: new_path,
				title: srcRow?.title ?? "",
				folder: newFolder,
				tags: srcRow?.tags ?? [],
				version: 1,
				mtime: now,
				created_at: now,
				updated_at: now,
			};

			// Drop the placeholder into the id-keyed list the tree reads (root or
			// subfolder). Only patch when cached; otherwise it lands on the next
			// expand fetch. Cancel first so an in-flight refetch can't clobber it.
			if (targetId != null) {
				const key = ["folder-notes-by-id", vaultId, targetId] as const;
				await qc.cancelQueries({ queryKey: key });
				const snapshot = qc.getQueryData<NoteSummary[]>(key);
				if (snapshot) {
					ctx.key = key;
					ctx.snapshot = snapshot;
					qc.setQueryData<NoteSummary[]>(key, [
						...snapshot.filter((n) => n.path !== new_path),
						placeholder,
					]);
				}
			}
			return ctx;
		},
		onSuccess: (data, _vars, ctx) => {
			if (!ctx?.key) return;
			const real = data.note;
			if (!real?.id) return;
			// Swap the placeholder for the real server row so a tree consumer keying
			// on `n.id` transitions smoothly. onSettled also invalidates; the swap
			// avoids a momentary "missing note" flash.
			patchRowInList(qc, ctx.key, ctx.placeholderId, {
				id: real.id,
				path: real.path,
				title: real.title,
				folder: real.folder,
				tags: real.tags,
				version: real.version,
				mtime: real.mtime,
				created_at: real.created_at,
				updated_at: real.updated_at,
			});
		},
		onError: (err, _vars, ctx) => {
			if (ctx?.key && ctx.snapshot !== undefined) {
				qc.setQueryData(ctx.key, ctx.snapshot);
			}
			if (err.status === 409) {
				toast.error("A note with that name already exists.");
			} else {
				toast.error("Failed to duplicate.");
			}
		},
		onSettled: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
		},
	});
}

// ── Batch mutations (tree multi-select — Task 19) ─────────────
//
// Four hooks fronting `/api/{notes,folders}/batch-{delete,move}`. The
// backend treats every batch atomically (all-or-nothing); the
// `X-Idempotency-Key` header is REQUIRED by the IdempotencyKey plug
// installed in Tasks 7/8 — a missing or replay-on-different-body header
// produces a 4xx the user shouldn't ever see.
//
// Optimistic strategy mirrors the per-row mutations above: snapshot
// affected caches on `onMutate`, patch them locally, restore on error,
// invalidate on success so the server reconciles authoritative state
// (folder counts, server-assigned timestamps, etc.).
//
// Cache keys we touch:
//   `['folders', vaultId]`              — the folder tree (id, parent_id, name)
//   `['folder-notes-by-id', vaultId, folderId]` — by-id note lists
//
// `['folderNotes', vaultId, folder]` (path-keyed) is invalidated alongside
// for the legacy tree consumers that still read it; the batch onMutate
// itself only patches the id-keyed list since headless-tree is the only
// caller that issues batches.

function idempotencyHeaders(): { headers: Record<string, string> } {
	return { headers: { "X-Idempotency-Key": crypto.randomUUID() } };
}

interface BatchNotesContext {
	// Every by-id list we patched (root included — it keys under ROOT_FOLDER_ID).
	// We keep the snapshot map ordered by the QueryClient cache scan so rollback
	// restores under the same key.
	noteListSnapshots: Array<{ key: readonly unknown[]; data: NoteSummary[] | undefined }>;
	// Folders cache snapshot — present only when a move patched folder counts
	// (so the tree's structure key changes and it rebuilds). Used for rollback.
	folders?: { folders: Folder[] };
}

export function useBatchDeleteNotes() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { ids: string[] }, BatchNotesContext>({
		mutationFn: ({ ids }) =>
			api.post<{ deleted: number }>("/notes/batch-delete", { ids }, idempotencyHeaders()),
		onMutate: async ({ ids }) => {
			await qc.cancelQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			const idSet = new Set(ids);

			// One id-keyed cache holds every note list (root keys under
			// ROOT_FOLDER_ID), so a single scan strips deleted rows everywhere.
			const snapshots: BatchNotesContext["noteListSnapshots"] = [];
			const queries = qc.getQueryCache().findAll({ queryKey: ["folder-notes-by-id", vaultId] });
			for (const q of queries) {
				const data = qc.getQueryData<NoteSummary[]>(q.queryKey);
				if (!data) continue;
				snapshots.push({ key: q.queryKey, data });
				qc.setQueryData<NoteSummary[]>(
					q.queryKey,
					data.filter((n) => !idSet.has(n.id)),
				);
			}

			// Drop any cached note body for the deleted ids so a stale
			// useNote(id) subscriber 404s on remount instead of rendering.
			for (const id of ids) {
				qc.removeQueries({ queryKey: ["note", vaultId, id] });
			}

			return { noteListSnapshots: snapshots };
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) return;
			for (const snap of ctx.noteListSnapshots) {
				qc.setQueryData(snap.key, snap.data);
			}
			toast.error("Batch delete failed.");
		},
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useBatchMoveNotes() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ moved: number },
		ApiError,
		{ ids: string[]; target_folder: string },
		BatchNotesContext
	>({
		mutationFn: ({ ids, target_folder }) =>
			api.post<{ moved: number }>(
				"/notes/batch-move",
				{ ids, target_folder },
				idempotencyHeaders(),
			),
		onMutate: async ({ ids, target_folder }) => {
			await qc.cancelQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			await qc.cancelQueries({ queryKey: ["folders", vaultId] });
			const idSet = new Set(ids);

			// Destination is the folder PATH ('' = vault root). The by-id note cache
			// keys under the folder's loader id — a real marker id, else the stable
			// `syn:<path>` id a derived folder carries — so the optimistic add lands
			// in the same list the tree reads.
			const foldersCache = qc.getQueryData<{ folders: Folder[] }>(["folders", vaultId]);
			const targetFolderName = target_folder;
			const targetCacheId =
				target_folder === ""
					? ROOT_FOLDER_ID
					: (foldersCache?.folders.find((f) => f.name === target_folder)?.id ??
						syntheticFolderId(target_folder));

			const snapshots: BatchNotesContext["noteListSnapshots"] = [];
			const moved: NoteSummary[] = [];
			// How many notes left each source folder, keyed by folder NAME — used to
			// decrement folder counts below. Keyed by name (not id) because a derived
			// folder's raw `['folders']` row has a null id, so id matching would miss
			// it; the note lists, however, are keyed by the loader id (real or syn:).
			const removedPerName = new Map<string, number>();

			// First pass: strip moved notes from every source list (capture the rows
			// so we can re-attach them to the target). Root and subfolders share one
			// id-keyed cache, so a single scan covers them all.
			for (const q of qc.getQueryCache().findAll({ queryKey: ["folder-notes-by-id", vaultId] })) {
				const data = qc.getQueryData<NoteSummary[]>(q.queryKey);
				if (!data) continue;
				snapshots.push({ key: q.queryKey, data });
				const folderId = q.queryKey[2] as string | null | undefined;
				// Resolve this source list's folder PATH so the count decrement matches
				// the raw folders cache by name (root sentinel → '', syn:<path> → path,
				// real id → its cached name).
				const srcName =
					typeof folderId !== "string"
						? null
						: folderId === ROOT_FOLDER_ID
							? ""
							: isSyntheticFolderId(folderId)
								? syntheticFolderPath(folderId)
								: (foldersCache?.folders.find((ff) => ff.id === folderId)?.name ?? null);
				const keep: NoteSummary[] = [];
				for (const n of data) {
					if (idSet.has(n.id) && folderId !== targetCacheId) {
						moved.push(n);
						if (srcName !== null) {
							removedPerName.set(srcName, (removedPerName.get(srcName) ?? 0) + 1);
						}
					} else {
						keep.push(n);
					}
				}
				qc.setQueryData<NoteSummary[]>(q.queryKey, keep);
			}

			// Second pass: append the moved rows to the destination list (if cached),
			// rewriting folder + path so each row looks at-home. The target keys
			// under its id — ROOT_FOLDER_ID for the vault root.
			if (moved.length > 0) {
				const dest = targetFolderName;
				const patched = moved.map<NoteSummary>((n) => {
					const filename = n.path.includes("/")
						? n.path.slice(n.path.lastIndexOf("/") + 1)
						: n.path;
					return { ...n, folder: dest, path: dest ? `${dest}/${filename}` : filename };
				});
				const targetKey = ["folder-notes-by-id", vaultId, targetCacheId] as const;
				const targetData = qc.getQueryData<NoteSummary[]>(targetKey);
				if (targetData) qc.setQueryData<NoteSummary[]>(targetKey, [...targetData, ...patched]);
			}

			// Patch the individual `['note', vaultId, id]` caches so an open viewer
			// reflects the new folder. Path/folder shift; id stable. Applies to root
			// targets too (dest === '').
			{
				const dest = targetFolderName;
				for (const id of ids) {
					const note = qc.getQueryData<Note>(["note", vaultId, id]);
					if (!note) continue;
					const filename = note.path.includes("/")
						? note.path.slice(note.path.lastIndexOf("/") + 1)
						: note.path;
					qc.setQueryData<Note>(["note", vaultId, id], {
						...note,
						folder: dest,
						path: dest ? `${dest}/${filename}` : filename,
					});
				}
			}

			// Bump folder counts: each source loses what it shed, the target gains
			// the total moved. Two reasons, both load-bearing: (1) keeps the folder
			// count value accurate (used by the delete-confirm child count) without a
			// refetch, and (2) flips the folders cache so the tree's structure key
			// (id:count:parent_id) changes and it rebuilds. The by-id cache write
			// also rebuilds via the useEngramTree subscription, so this is belt-and-
			// suspenders for rebuild but the SOLE optimistic source for the count.
			// Snapshot for rollback. Skipped when nothing moved; for a root target
			// ('root' has no folder row) sources still decrement.
			let foldersSnapshot: { folders: Folder[] } | undefined;
			if (moved.length > 0 || removedPerName.size > 0) {
				const cache = qc.getQueryData<{ folders: Folder[] }>(["folders", vaultId]);
				if (cache) {
					foldersSnapshot = cache;
					const patched = cache.folders.map((f) => {
						let count = f.count;
						// Both source decrement and destination bump match by NAME: a
						// derived folder has a null id in the raw cache, so id matching
						// would miss it.
						const removed = removedPerName.get(f.name);
						if (removed) count -= removed;
						if (target_folder !== "" && f.name === target_folder) count += moved.length;
						return count === f.count ? f : { ...f, count };
					});
					qc.setQueryData<{ folders: Folder[] }>(["folders", vaultId], { folders: patched });
				}
			}

			return { noteListSnapshots: snapshots, folders: foldersSnapshot };
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) return;
			for (const snap of ctx.noteListSnapshots) {
				qc.setQueryData(snap.key, snap.data);
			}
			if (ctx.folders !== undefined) qc.setQueryData(["folders", vaultId], ctx.folders);
			toast.error("Batch move failed.");
		},
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

// Walk the folders cache and collect `id` plus every transitive
// descendant by parent_id chain. Used by both batch folder mutations.
function collectFolderDescendants(folders: Folder[], rootIds: string[]): Set<string> {
	const result = new Set<string>(rootIds);
	// Iterate until no new ids land in the set — folders are typically
	// shallow, so this is cheap even with the naive scan.
	let changed = true;
	while (changed) {
		changed = false;
		for (const f of folders) {
			if (f.parent_id != null && result.has(f.parent_id) && !result.has(f.id)) {
				result.add(f.id);
				changed = true;
			}
		}
	}
	return result;
}

interface BatchFoldersContext {
	folders: { folders: Folder[] } | undefined;
	// Snapshot every by-id note list whose folder is being deleted so
	// rollback can restore them. Move doesn't touch these lists.
	noteListSnapshots: Array<{ key: readonly unknown[]; data: NoteSummary[] | undefined }>;
}

export function useBatchDeleteFolders() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { ids: string[] }, BatchFoldersContext>({
		mutationFn: ({ ids }) =>
			api.post<{ deleted: number }>("/folders/batch-delete", { ids }, idempotencyHeaders()),
		onMutate: async ({ ids }) => {
			const foldersKey = ["folders", vaultId] as const;
			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: ["folder-notes-by-id", vaultId] });

			const folders = qc.getQueryData<{ folders: Folder[] }>(foldersKey);
			const ctx: BatchFoldersContext = { folders, noteListSnapshots: [] };

			// Compute the full set of ids (roots + transitive descendants)
			// so the optimistic patch matches the server's cascade.
			const removedIds = folders
				? collectFolderDescendants(folders.folders, ids)
				: new Set<string>(ids);

			if (folders) {
				qc.setQueryData<{ folders: Folder[] }>(foldersKey, {
					folders: folders.folders.filter((f) => !removedIds.has(f.id)),
				});
			}

			// Drop the by-id note lists for every removed folder.
			for (const fid of removedIds) {
				const key = ["folder-notes-by-id", vaultId, fid] as const;
				const data = qc.getQueryData<NoteSummary[]>(key);
				if (data !== undefined) {
					ctx.noteListSnapshots.push({ key, data });
					qc.removeQueries({ queryKey: key });
				}
			}

			return ctx;
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) return;
			if (ctx.folders !== undefined) qc.setQueryData(["folders", vaultId], ctx.folders);
			for (const snap of ctx.noteListSnapshots) {
				qc.setQueryData(snap.key, snap.data);
			}
			toast.error("Batch delete failed.");
		},
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useBatchMoveFolders() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ moved: number },
		ApiError,
		{ ids: string[]; target_parent: string },
		BatchFoldersContext
	>({
		mutationFn: ({ ids, target_parent }) =>
			api.post<{ moved: number }>(
				"/folders/batch-move",
				// Move by PATH (target_parent) so a derived parent with no marker works.
				{ ids, target_parent },
				idempotencyHeaders(),
			),
		onMutate: async ({ ids, target_parent }) => {
			const foldersKey = ["folders", vaultId] as const;
			await qc.cancelQueries({ queryKey: foldersKey });

			const folders = qc.getQueryData<{ folders: Folder[] }>(foldersKey);
			const ctx: BatchFoldersContext = { folders, noteListSnapshots: [] };
			if (!folders) return ctx;

			// Destination is the parent PATH ('' = top level). Children link to the
			// target's loader id — a real marker id, else the stable `syn:<path>` id a
			// derived parent carries (its raw-cache id is null).
			const targetName = target_parent;
			const targetCacheId =
				target_parent === ""
					? null
					: (folders.folders.find((f) => f.name === target_parent)?.id ??
						syntheticFolderId(target_parent));
			const descendants = collectFolderDescendants(folders.folders, ids);
			// Cycle defense by path: the target is one of the moved folders or sits
			// under one. Skip the optimistic patch and let the server reject (it has
			// the authoritative cycle check). Frontend silence beats lying.
			const movedNames = folders.folders.filter((f) => ids.includes(f.id)).map((f) => f.name);
			if (movedNames.some((n) => target_parent === n || target_parent.startsWith(`${n}/`))) {
				return ctx;
			}

			// Rewrite each moved root: parent_id flips to the target,
			// name path prefix is rebuilt as `${targetName}/${basename}`.
			// Descendants keep their parent_id (still relative to their
			// intra-subtree parent) but their .name prefix is rewritten so
			// the path string stays coherent.
			const idSet = new Set(ids);
			const patched = folders.folders.map<Folder>((f) => {
				if (idSet.has(f.id)) {
					const slash = f.name.lastIndexOf("/");
					const basename = slash < 0 ? f.name : f.name.slice(slash + 1);
					return {
						...f,
						parent_id: targetCacheId,
						name: targetName ? `${targetName}/${basename}` : basename,
					};
				}
				if (descendants.has(f.id)) {
					// Find the ancestor in the moved set whose name is the
					// longest prefix of `f.name` — that's the root whose path
					// we just rewrote. Compose the descendant's new name by
					// stripping the OLD ancestor prefix and re-attaching the NEW.
					const oldOriginal = folders.folders.find(
						(m) => idSet.has(m.id) && (f.name === m.name || f.name.startsWith(`${m.name}/`)),
					);
					if (!oldOriginal) return f;
					const slash = oldOriginal.name.lastIndexOf("/");
					const basename = slash < 0 ? oldOriginal.name : oldOriginal.name.slice(slash + 1);
					const newRoot = targetName ? `${targetName}/${basename}` : basename;
					const tail = f.name === oldOriginal.name ? "" : f.name.slice(oldOriginal.name.length + 1);
					return { ...f, name: tail ? `${newRoot}/${tail}` : newRoot };
				}
				return f;
			});

			qc.setQueryData<{ folders: Folder[] }>(foldersKey, { folders: patched });
			return ctx;
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) return;
			if (ctx.folders !== undefined) qc.setQueryData(["folders", vaultId], ctx.folders);
			toast.error("Batch move failed.");
		},
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useRenameAttachment() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ renamed: boolean; old_path: string; new_path: string },
		ApiError,
		{ old_path: string; new_path: string }
	>({
		mutationFn: (vars) =>
			api.post<{ renamed: boolean; old_path: string; new_path: string }>(
				"/attachments/rename",
				vars,
			),
		onSettled: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
		},
	});
}

export function useBatchMoveAttachments() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ moved: number }, ApiError, { paths: string[]; target_folder: string }>({
		mutationFn: ({ paths, target_folder }) =>
			api.post<{ moved: number }>(
				"/attachments/batch-move",
				{ paths, target_folder },
				idempotencyHeaders(),
			),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
		},
		// Batch moves are fire-and-forget (.mutate, no caller .catch) — surface
		// failures here, matching the note/folder batch hooks.
		onError: () => {
			toast.error("Batch move failed.");
		},
	});
}

export function useBatchDeleteAttachments() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { paths: string[] }>({
		mutationFn: ({ paths }) =>
			api.post<{ deleted: number }>("/attachments/batch-delete", { paths }, idempotencyHeaders()),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
		},
		onError: () => {
			toast.error("Batch delete failed.");
		},
	});
}
