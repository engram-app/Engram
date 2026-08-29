import type { EditorView } from "@codemirror/view";
import { BookOpen, Pencil } from "lucide-react";
import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocation, useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import type { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { isNotFound } from "../api/client";
import type { Note } from "../api/queries";
import {
	useBatchMoveNotes,
	useDeleteNote,
	useDuplicateNote,
	useFolders,
	useNote,
	useRenameNote,
	useSyncManifest,
} from "../api/queries";
import { readRows } from "../crdt/frontmatter-doc";
import { crdtMark } from "../crdt/perf";
import {
	type CrdtSyncStatus,
	closeDoc,
	enroll,
	getCrdtSyncStatus,
	openDoc,
	subscribeToCrdtSyncStatus,
} from "../crdt/session";
import { useRightToolSlot } from "../layout/right-tools-context";
import { copyToClipboard } from "../lib/clipboard";
import { noteName } from "../lib/note-name";
import { rlog } from "../observability/remote-log";
import { vaultPath } from "../routes";
import BacklinksPanel from "./backlinks-panel";
import { useActiveEditor } from "./editor/active-editor-context";
import { KeyboardBar } from "./editor/keyboard-bar";
import { RawFrontmatterEditor } from "./editor/raw-frontmatter-editor";
import { InlineTitle } from "./inline-title";
import LoadingPane from "./loading-pane";
import { NoteEditor } from "./note-chunks";
import { NoteMenu } from "./note-menu";
import NoteToc from "./note-toc";
import NoteView from "./note-view";
import { PropertiesWidget } from "./properties-widget";
import type { ActionId, ViewMode } from "./tree-actions/action-list";
import { DeleteConfirm } from "./tree-actions/delete-confirm";
import { nextCopyName } from "./tree-actions/duplicate";
import { MoveDialog } from "./tree-actions/move-dialog";
import { RenameInput } from "./tree-actions/rename-input";
import { renameBaseName } from "./tree-actions/rename-path";
import { useLiveContent } from "./use-live-content";
import { buildWikiMap, wikiHref } from "./wiki-link";

/** How long the routed note may fail to open before the pane explains itself. */
const STALL_NOTICE_MS = 1500;

interface DocHandle {
	ytext: Y.Text;
	awareness: Awareness;
	doc: Y.Doc;
}

/** A note and the doc its body is being edited in — always the SAME note. */
interface Displayed {
	note: Note;
	handle: DocHandle | null;
}

export default function NotePage() {
	const { itemId: idStr, slug } = useParams();
	const validId = idStr && idStr.length > 0 ? idStr : null;

	const { data: fetchedNote, isLoading, isPlaceholderData, error } = useNote(validId);

	// ── The committed pair ───────────────────────────────────────────────────
	// INVARIANT: this page NEVER renders one note's chrome over another note's
	// document. `shown` is that pair — note data plus the doc handle its body is
	// bound to — and it is the ONLY thing anything below may read. It advances
	// solely when both halves are ready for the same note id; until then the
	// PREVIOUS pair keeps rendering in full, chrome included, so a mismatch has
	// nowhere to appear.
	//
	// `useNote` holds the note you were reading while the next one loads
	// (placeholderData), so its `data` can name a note the URL no longer points
	// at. That makes it unsafe as a source on its own — hence `routedNote`.
	const routedNote = fetchedNote && fetchedNote.id === validId ? fetchedNote : null;
	// CRDT manages MARKDOWN only — mirrors the server-side `.md` gate
	// (crdt_deliver.ex). note_id carries no extension, so the check has to happen
	// here, against the routed note's current path.
	const openId = routedNote?.path.endsWith(".md") ? routedNote.id : null;
	const [opened, setOpened] = useState<{ id: string; handle: DocHandle } | null>(null);
	const [displayed, setDisplayed] = useState<Displayed | null>(null);
	const openedHandle = routedNote && opened?.id === routedNote.id ? opened.handle : null;
	// Three ways a pair is complete:
	//   - its doc is open (the ordinary case);
	//   - it has no doc to wait for (canvas & co), so data alone completes it;
	//   - nothing has EVER been committed — a first-ever load, hard refresh or
	//     deep link. A note's chrome over NO document violates nothing: there is
	//     no other document a keystroke could land in, and the editor area has
	//     its own empty state. Making the cold case wait for both halves only
	//     bought a full-pane spinner on every refresh.
	// Every SUBSEQUENT swap still demands both halves — that is where a mismatch
	// could put keystrokes in the wrong note's document.
	// ...and one way a committed pair may be REFRESHED rather than swapped: the
	// same note id, with no doc committed yet. That is the vault-tree placeholder
	// being replaced by the fetched note (content, tags, links), and without it
	// the stub would spend the `displayed === null` allowance above and then hold
	// the pane hostage — the real note could never commit until a handle opened,
	// and never at all if openDoc stalled, with no spinner or stall notice to say
	// so. Requiring `displayed.handle === null` keeps it a refresh and not a swap:
	// same note, no live document to mismatch against.
	const isSameNoteRefresh =
		routedNote !== null && displayed !== null && displayed.handle === null
			? displayed.note.id === routedNote.id
			: false;
	const ready: Displayed | null =
		routedNote &&
		(openedHandle !== null || openId === null || displayed === null || isSameNoteRefresh)
			? { note: routedNote, handle: openedHandle }
			: null;
	if (ready && (ready.note !== displayed?.note || ready.handle !== displayed?.handle)) {
		// React's documented "adjust state during render" (same pattern as
		// draftNoteId below) — an effect would paint one frame of the stale pair
		// first, which is the flash this page exists to avoid.
		setDisplayed(ready);
	}
	const shown = ready ?? displayed;
	const handle = shown?.handle ?? null;
	// True while the pane is showing the vault-tree stub rather than fetched
	// data: same note id as the route, but the query is still on placeholder
	// data. Gates the path-keyed actions below.
	const chromeIsPlaceholder = isPlaceholderData && shown?.note.id === validId && !shown.handle;

	const { data: manifest } = useSyncManifest();
	const { setEditor } = useActiveEditor();

	const navigate = useNavigate();
	const { data: folders } = useFolders();
	const deleteNote = useDeleteNote();
	const duplicateNote = useDuplicateNote();
	const batchMoveNotes = useBatchMoveNotes();
	const [dialog, setDialog] = useState<"move" | "delete" | null>(null);
	// Local-only: an "open but empty" properties block, from the `---` gesture.
	// Never written to the Y.Doc — the other devices should not sprout an empty
	// frontmatter section because someone typed three dashes here.
	const [frontmatterDraft, setFrontmatterDraft] = useState(false);

	const [mode, setMode] = useState<ViewMode>("rendered");
	// Written only from the reading toggle's handler, never during render.
	const lastEditMode = useRef<Exclude<ViewMode, "reading">>("rendered");
	// Which note the rename box belongs to, not a bare boolean: navigating to
	// another note keeps this component mounted, and an id-keyed value closes
	// the box on its own instead of carrying over onto the newly opened note.
	//
	// `at` names the surface because there are two of them — the header path and
	// the inline title. Rendering a box in both would put two autofocusing
	// inputs on screen, each committing the other's blur.
	const [renaming, setRenaming] = useState<{ id: string; at: "header" | "title" } | null>(null);
	const renameNote = useRenameNote();
	const [syncStatus, setSyncStatus] = useState<CrdtSyncStatus>(getCrdtSyncStatus);
	const editorViewRef = useRef<EditorView | null>(null);
	// Same lookup NoteView builds for its remark-wiki-link hrefTemplate — a
	// resolved link routes straight to the note id instead of through the
	// lazy /:slug/wiki/* resolver.
	const wikiMap = useMemo(() => buildWikiMap(shown?.note.links), [shown?.note.links]);
	// Manifest layer for wikiHref, read through a ref (same identity-stability
	// reasoning as manifestPathsRef below): edges lag behind fresh links, the
	// manifest resolves them without the /wiki redirect flash, and a manifest
	// refetch must not change these callbacks' identity.
	const wikiManifestRef = useRef<{ id: string; path: string }[]>([]);
	// biome-ignore lint/nursery/useReactCompiler: latest-ref pattern, deliberate. Writing during render is the point: it keeps the callback identity stable so the consuming effect does not re-fire on every render. See the comment above.
	wikiManifestRef.current = manifest?.notes ?? [];
	// useCallback keeps a stable identity so passing it to NoteEditor doesn't
	// re-fire the decorationsCompartment reconfigure effect on every render.
	const resolveWikiLink = useCallback(
		(permalink: string) => wikiHref(permalink, slug, wikiMap, wikiManifestRef.current),
		[slug, wikiMap],
	);
	// Editor-mode click-to-open. Router nav must come from the React tree —
	// see LivePreviewOpts.openWikiLink for why the editor can't reach the
	// router singleton itself.
	const openWikiLink = useCallback(
		(permalink: string) => {
			const href = wikiHref(permalink, slug, wikiMap, wikiManifestRef.current);
			if (href.startsWith("/")) {
				navigate(href);
			} else if (href.startsWith("#")) {
				// Same-page heading — hash assignment scrolls, no reload.
				window.location.hash = href;
			}
		},
		[navigate, slug, wikiMap],
	);
	// `[[` autocomplete's candidate list. Read through a ref, not a useMemo keyed
	// on manifest, so this callback's identity NEVER changes -- the manifest
	// query refetches on its own staleTime, and a new function identity there
	// would fire NoteEditor's decorationsCompartment.reconfigure effect for
	// every refetch with no UI change to show for it (same onView/onShortcutRef
	// reasoning documented in note-editor.tsx).
	const manifestPaths = useMemo(() => manifest?.notes.map((n) => n.path) ?? [], [manifest]);
	const manifestPathsRef = useRef<string[]>([]);
	// biome-ignore lint/nursery/useReactCompiler: latest-ref pattern, deliberate. Writing during render is the point: it keeps the callback identity stable so the consuming effect does not re-fire on every render. See the comment above.
	manifestPathsRef.current = manifestPaths;
	const wikiCompletionPaths = useCallback(() => manifestPathsRef.current, []);

	// ── Doc lifecycle ────────────────────────────────────────────────────────
	// Open the routed note's CRDT doc, keyed by its stable note_id (NOT path — a
	// rename/move must not tear down and rebuild the live doc), and enroll for
	// the STEP1 handshake. yCollab (in NoteEditor) owns convergence — there is no
	// REST autosave, 3-way merge, or conflict UI on this path anymore.
	//
	// Nothing here releases the note you came from: that belongs to the committed
	// pair, below, because closeDoc DESTROYS the Y.Doc and the outgoing editor
	// stays bound to it until React commits the swap.
	//
	// note_ids this page has open and has not released. At most two: the one on
	// screen and the one being opened behind it.
	const openedIdsRef = useRef<Set<string>>(new Set());
	// The doc the MOUNTED editor is bound to. Written from an effect, never
	// during render — a render React throws away must not be able to mark a live
	// document as safe to destroy.
	const boundIdRef = useRef<string | null>(null);
	const release = useCallback((id: string) => {
		if (openedIdsRef.current.delete(id)) {
			closeDoc(id);
			// Drop the handle with it. A released doc is a DESTROYED doc, and
			// keeping it around meant a return visit (md → canvas → md, where the
			// canvas commit releases without a new handle replacing it) committed
			// the dead one before the re-open could land.
			setOpened((cur) => (cur?.id === id ? null : cur));
		}
	}, []);
	// What the page wants open. A late openDoc releases its own doc only once the
	// page has moved on — without that check StrictMode's mount/cleanup/mount
	// would close the doc the second open just handed us.
	const wantIdRef = useRef<string | null>(null);
	// Mirrors `opened` for the async callbacks below, which must not re-open a
	// doc this page already holds (a redundant open also means a redundant
	// `enroll`, and handshake starvation is a known bug class here).
	const openedRef = useRef<typeof opened>(null);
	useEffect(() => {
		openedRef.current = opened;
	}, [opened]);
	useEffect(() => {
		wantIdRef.current = openId;
		if (openId === null) {
			return;
		}
		let cancelled = false;
		const attempt = () => {
			if (cancelled || openedRef.current?.id === openId) {
				return;
			}
			openDoc(openId).then((h) => {
				if (!h) {
					// Open failed. Nothing to commit, so the previous pair keeps
					// rendering — whole, and honest about it.
					return;
				}
				openedIdsRef.current.add(openId);
				if (cancelled || wantIdRef.current !== openId) {
					// Never reached the screen, so release it rather than leak it —
					// UNLESS this is the doc the mounted editor is bound to, which
					// happens when two opens for the same note are outstanding and the
					// page moves on between them: closeDoc would destroy a live
					// document out from under the binding, silently dropping
					// keystrokes. The pair swap below releases it at the right moment.
					if (wantIdRef.current !== openId && boundIdRef.current !== openId) {
						release(openId);
					}
					return;
				}
				setOpened({ id: openId, handle: h });
				enroll(openId);
			});
		};
		attempt();
		// A session torn down MID-open makes openDoc SETTLE as a failure (null),
		// and nothing would ever ask again — the note stays unopenable until the
		// user navigates away and back. A PARKED open is the opposite and needs no
		// help: startCrdtSession drains every waiter and only bumps the generation
		// when a session was actually running, so an open waiting on a session
		// resolves by itself the moment one starts. So this is not a retry loop —
		// it is one re-ask per sync-status transition, skipped entirely once we
		// hold the routed doc.
		const unsubscribe = subscribeToCrdtSyncStatus(attempt);
		return () => {
			cancelled = true;
			unsubscribe();
		};
	}, [openId, release]);

	// Release the outgoing doc only AFTER React has committed the swap. closeDoc
	// destroys the Y.Doc; running it in the same tick as the state update leaves
	// the outgoing EditorView holding a destroyed document for a render cycle.
	const boundId = shown?.handle ? shown.note.id : null;
	useEffect(() => {
		const prev = boundIdRef.current;
		boundIdRef.current = boundId;
		if (prev && prev !== boundId) {
			release(prev);
		}
	}, [boundId, release]);

	// Nothing above closes on the way out, so the page owns the final release.
	// Empty deps: this runs once, on unmount.
	useEffect(
		() => () => {
			wantIdRef.current = null;
			boundIdRef.current = null;
			for (const id of openedIdsRef.current) {
				closeDoc(id);
			}
			openedIdsRef.current.clear();
		},
		[],
	);

	// Subscribe to CRDT sync status changes (non-blocking -- editor still works offline).
	useEffect(() => subscribeToCrdtSyncStatus(setSyncStatus), []);

	// The note actually on screen, not the one being routed to. Every consumer
	// below reads these, never the routed note -- that is the invariant.
	const shownPath = shown?.note.path;
	const shownId = shown?.note.id ?? null;

	// ToC reads the materialized REST content (refreshed by note_changed).
	// Hoist the two primitives the effect actually depends on so the captured
	// values match the dependency list (a new `note` object identity each
	// render would otherwise rebuild the ToC needlessly).
	const notePath = shownPath;
	const noteContent = shown?.note.content;
	const liveContent = useLiveContent(handle?.ytext ?? null, noteContent ?? "");
	const outlineNode = useMemo(
		() => (notePath === undefined ? null : <NoteToc content={liveContent} />),
		[notePath, liveContent],
	);
	useRightToolSlot("outline", outlineNode);

	// Backlinks only need the note id (the panel fetches its own data), so this
	// doesn't need to re-fire on every keystroke the way the ToC's effect does.
	const backlinksNode = useMemo(
		() => (shownId === null ? null : <BacklinksPanel noteId={shownId} />),
		[shownId],
	);
	useRightToolSlot("backlinks", backlinksNode);

	// Consume the just-created flag exactly once: start renaming, then strip the
	// state so a later back-navigation to this history entry doesn't reopen the
	// rename box on a note the user already named.
	//
	// It has to wait for the NEW note to be the committed one. Spending it on
	// whatever is still on screen opens a rename box holding the previous note's
	// name and clears the flag, so Enter renames that note and the new one never
	// enters rename mode at all.
	const location = useLocation();
	const state: unknown = location.state;
	const justCreated =
		typeof state === "object" && state !== null && "justCreated" in state
			? Boolean(state.justCreated)
			: false;
	useEffect(() => {
		if (!(justCreated && shownId && shownId === validId)) {
			return;
		}
		// biome-ignore lint/nursery/useReactCompiler: consumes a one-shot router flag: it must both start the rename AND strip history state, so it cannot be derived. Guarded to run once per (justCreated, shownId).
		setRenaming({ id: shownId, at: "title" });
		navigate(location.pathname, { replace: true, state: {} });
	}, [justCreated, shownId, validId, navigate, location.pathname]);

	// The draft belongs to the note you are looking at, not to the page, which
	// stays mounted across note switches. Adjusted during render rather than in
	// an effect — React's documented pattern for resetting state on a prop
	// change, and it avoids rendering the stale draft for one frame.
	const [draftNoteId, setDraftNoteId] = useState(shownId);
	if (draftNoteId !== shownId) {
		setDraftNoteId(shownId);
		setFrontmatterDraft(false);
	}

	// Holding the previous note is honest about DATA but silent about INTENT:
	// the user clicked a note and it never opened. Say so — without taking the
	// readable note away, because nothing is being lost by waiting. Derived, not
	// stored, so it clears itself when the doc opens, when the user navigates
	// elsewhere, and when the session recovers.
	const stalled = shown !== null && shown.note.id !== validId;
	const [stalledLong, setStalledLong] = useState(false);
	useEffect(() => {
		if (!stalled) {
			// Must reset, not just skip: without this the flag would mean "stalled
			// at some point during this mount", and coming back to a note that
			// stalled once would flash the strip with no debounce at all.
			// biome-ignore lint/nursery/useReactCompiler: the reset has no render-phase form -- deriving it from `stalled` alone loses the 1.5s debounce, and keying it on the note id leaks across visits.
			setStalledLong(false);
			return;
		}
		// Not immediately: an ordinary open takes a moment, and a strip on every
		// click is noise worse than the flash this page removed.
		const timer = setTimeout(() => setStalledLong(true), STALL_NOTICE_MS);
		return () => clearTimeout(timer);
	}, [stalled]);

	// Publish the editor so right-sidebar tools (the markdown reference panel)
	// can insert at the caret. Gated on the SAME condition that renders
	// NoteEditor below, so "Insert" is disabled in reading mode and on
	// non-markdown items rather than silently doing nothing.
	const editorMounted = handle !== null && mode !== "reading";
	useEffect(() => {
		if (!editorMounted) {
			return;
		}
		setEditor(() => editorViewRef.current);
		return () => setEditor(null);
	}, [editorMounted, setEditor]);

	// The routed note is gone — deleted from another device, or by this one's
	// own delete action racing the route. A 404 here means there is no note to
	// show, not a failure to explain, so bounce to the bare vault instead of
	// stranding the user on a red-text dead end. Logged (not silent): a 404 can
	// also mean a real backend bug (bad auth/vault scoping), and that must stay
	// diagnosable even though the redirect makes it invisible in the UI.
	const noteGone = isNotFound(error);
	useEffect(() => {
		if (!noteGone || validId === null) {
			return;
		}
		rlog().warn("note", `note ${validId} 404'd while routed — redirecting to vault root`);
		navigate(slug ? vaultPath(slug) : "/", { replace: true });
	}, [noteGone, validId, navigate, slug]);

	if (validId === null) {
		return <p className="p-6 text-destructive">Invalid note id.</p>;
	}
	if (noteGone) {
		// Redirecting (see the effect above) — nothing to show for the one tick
		// it takes.
		return null;
	}
	if (error) {
		// The ROUTED note failed for a reason other than "it's gone" — never
		// paper over that with the held pair.
		return <p className="p-6 text-destructive">Failed to load note: {error.message}</p>;
	}
	if (!shown) {
		// Nothing has ever been committed: this is the cold first open, the one
		// case where a spinner is the honest answer. A `routedNote` here means its
		// data has landed and only its doc is outstanding — still a load, not a 404.
		return routedNote || isLoading ? (
			<LoadingPane />
		) : (
			<p className="p-6 text-muted-foreground">Note not found</p>
		);
	}

	// From here down there is exactly ONE note: the committed one. Every
	// consumer — header path, inline title, rename, kebab actions, properties,
	// the editor — reads it, so none of them can act on a note whose document
	// isn't the one on screen.
	const { note } = shown;
	// Id-keyed, not a bare boolean: the box belongs to a note, so it closes on
	// its own when another note becomes the committed one instead of carrying
	// over onto it.
	const renamingAt = renaming && renaming.id === note.id ? renaming.at : null;
	const name = noteName(note.path);
	const titlePath = note.folder ? `${note.folder}/${name}` : name;
	const commitRename = (next: string) => {
		setRenaming(null);
		// Base-name rename: the header never shows the extension, so the user
		// can't change the file type from here — the original one is always
		// re-attached. (The tree's rename is the place to swap .md <-> .canvas.)
		const new_path = renameBaseName(note.path, next);
		if (new_path === note.path) {
			return;
		}
		// `mutate`, not `mutateAsync` — the mutation's onError owns the toast.
		renameNote.mutate({ id: note.id, old_path: note.path, new_path });
	};

	// `---` on the first line opens the properties editor instead of leaving a
	// horizontal rule. Declined — so the fence survives as a real rule — when
	// the note already has frontmatter (the editor is showing anyway) or when
	// raw mode is up, where the YAML block is the frontmatter surface.
	const handleFrontmatterShortcut = () => {
		// Declining when the editor is ALREADY open matters: accepting deletes the
		// user's three characters, and setting an unchanged flag is a React
		// bailout that would open nothing in exchange for them.
		if (frontmatterDraft || mode !== "rendered" || !handle || readRows(handle.doc).length > 0) {
			return false;
		}
		setFrontmatterDraft(true);
		return true;
	};

	// Obsidian's binary edit/read toggle, sitting beside the kebab that still
	// carries all three modes. Raw counts as an EDIT mode, so returning from
	// reading restores whichever editor you left rather than always landing on
	// rendered — a round trip must not silently demote raw.
	const toggleReading = () => {
		if (mode === "reading") {
			setMode(lastEditMode.current);
			return;
		}
		lastEditMode.current = mode;
		setMode("reading");
	};

	// Deliberately NOT shared with folder-tree.tsx's handleActionPick: that one
	// is welded to tree state (getItemInstance().startRenaming(), rowsFor, its
	// own dialog reducer). The portable parts — the action list and the dialog
	// components — are already reused. See the design spec.
	const handleAction = (action: ActionId) => {
		// Path-keyed mutations must not fire off the vault-tree placeholder. Its
		// `path` comes from a cache with no freshness guarantee, so if the note
		// was renamed or moved on another device and the tree hasn't refetched,
		// rename/move/duplicate would send a path the server no longer knows —
		// a 404, or worse a rename computed from the wrong basename. The window
		// is short (it closes when the REST note lands) but the menu is on
		// screen for all of it. Id-keyed actions (delete, view modes, copy) are
		// unaffected and stay live.
		if (
			chromeIsPlaceholder &&
			(action === "rename" || action === "move" || action === "duplicate")
		) {
			toast.info("Still loading this note — try again in a moment");
			return;
		}
		switch (action) {
			case "view-rendered":
				setMode("rendered");
				break;
			case "view-raw":
				setMode("raw");
				break;
			case "view-reading":
				setMode("reading");
				break;
			case "rename":
				setRenaming({ id: note.id, at: "title" });
				break;
			case "move":
				setDialog("move");
				break;
			case "delete":
				setDialog("delete");
				break;
			case "duplicate": {
				// No reliable sibling-name set on hand — pass an empty Set and let the
				// backend reject a collision; the toast surfaces it. Mirrors the tree.
				const new_path = nextCopyName(note.path, new Set<string>());
				// `mutate`, not `mutateAsync` — the hook's onError already toasts, and
				// it distinguishes a name collision from a general failure. Catching
				// here too put a second, vaguer toast on top of the useful one.
				duplicateNote.mutate(
					{ src_path: note.path, new_path },
					{ onSuccess: () => toast.success("Duplicated") },
				);
				break;
			}
			case "copy-wikilink":
				// Wikilinks resolve by filename in Obsidian, never by H1 title.
				copyToClipboard(`[[${name || note.path}]]`).then((ok) =>
					ok ? toast.success("Copied wikilink") : toast.error("Copy failed"),
				);
				break;
			case "add-property":
				// Opens the adder row rather than writing a key. Inventing a name
				// meant a second use silently collided and did nothing, and from
				// reading or raw mode — where this widget is not on screen — it wrote
				// a property the user could not see but every other device received.
				// Forcing rendered mode makes the row it opens actually visible.
				setMode("rendered");
				setFrontmatterDraft(true);
				break;
			default:
				break;
		}
	};

	return (
		<section className="mx-auto flex size-full min-h-0 min-w-0 max-w-[840px] flex-col overflow-hidden border-border border-x bg-card text-card-foreground md:-my-6 md:h-[calc(100%+3rem)]">
			{syncStatus === "error" && (
				<p role="status" className="shrink-0 bg-destructive/10 px-4 py-1 text-destructive text-xs">
					Not syncing - reconnecting...
				</p>
			)}
			{stalled && stalledLong ? (
				<p role="status" className="shrink-0 bg-muted px-4 py-1 text-muted-foreground text-xs">
					Still opening {routedNote ? `“${noteName(routedNote.path)}”` : "that note"} — showing “
					{name}” until it does.
				</p>
			) : null}
			{/* The big title moved into the document so it scrolls away, but the
			    path stays pinned here — it is the only rename affordance still
			    reachable once you have scrolled the title out of view. */}
			<div className="flex shrink-0 items-center gap-2 border-border border-b px-4 py-2">
				<p className="flex min-w-0 flex-1 items-baseline gap-1 text-sm" title={titlePath}>
					{Boolean(note.folder) && (
						<span className="min-w-0 shrink truncate text-muted-foreground">{note.folder}/</span>
					)}
					{renamingAt === "header" ? (
						<RenameInput
							initial={name}
							kind="file"
							// This reads as a title field, not a modal edit: you click it,
							// retype, and click into the document. Losing the rename because
							// you did not press Enter is a surprise, so focus leaving saves.
							// Escape still abandons.
							commitOnBlur
							onCommit={commitRename}
							onCancel={() => setRenaming(null)}
						/>
					) : (
						<button
							type="button"
							data-testid="header-note-name"
							// -mx-1 cancels the padding so the hover target is roomier than
							// the text without nudging the name off the folder crumb.
							className="-mx-1 min-w-0 truncate rounded px-1 font-medium hover:bg-accent"
							title="Click to rename"
							onClick={() => setRenaming({ id: note.id, at: "header" })}
						>
							{name}
						</button>
					)}
				</p>
				<Button
					variant="ghost"
					size="icon"
					// The icon shows the mode you are IN — book while reading, pencil
					// while editing — so the name has to stay put and let aria-pressed
					// carry the state. A name that flipped to the next action would
					// tell a screen reader the opposite of what the icon shows.
					aria-label="Reading view"
					aria-pressed={mode === "reading"}
					title="Reading view"
					onClick={toggleReading}
				>
					{mode === "reading" ? <BookOpen className="size-4" /> : <Pencil className="size-4" />}
				</Button>
				<NoteMenu mode={mode} title={name} onPick={handleAction} />
			</div>

			{/* EditorToolbar is still NOT mounted — see editor/toolbar.tsx. The
			    mobile case that comment anticipated is KeyboardBar below, which
			    docks above the on-screen keyboard and carries only the commands a
			    soft keyboard cannot reach. It renders nothing on desktop or while
			    the keyboard is down. */}
			{mode !== "reading" && <KeyboardBar getView={() => editorViewRef.current} />}

			<ScrollArea className="min-h-0 flex-1">
				<div className="w-full pb-5">
					<InlineTitle
						name={name}
						renaming={renamingAt === "title"}
						onStartRename={() => setRenaming({ id: note.id, at: "title" })}
						onCommitRename={commitRename}
						onCancelRename={() => setRenaming(null)}
					/>

					{handle && mode === "rendered" ? (
						<PropertiesWidget
							doc={handle.doc}
							draft={frontmatterDraft}
							onAbandonDraft={() => setFrontmatterDraft(false)}
						/>
					) : null}
					{handle && mode === "raw" ? <RawFrontmatterEditor doc={handle.doc} /> : null}

					{mode === "reading" ? (
						// pt matches .cm-content's 20px top padding in note-editor.tsx so
						// the title sits the same distance above the body in reading mode
						// as it does in the editor.
						<div className="px-5 pt-5">
							<NoteView
								content={liveContent}
								tags={note.tags}
								links={note.links}
								manifestNotes={manifest?.notes}
							/>
						</div>
					) : (
						<Suspense fallback={<p className="p-5 text-muted-foreground">Loading editor…</p>}>
							{handle ? (
								<NoteEditor
									ytext={handle.ytext}
									awareness={handle.awareness}
									mode={mode === "raw" ? "raw" : "rendered"}
									resolveWikiLink={resolveWikiLink}
									openWikiLink={openWikiLink}
									wikiCompletionPaths={wikiCompletionPaths}
									onFrontmatterShortcut={handleFrontmatterShortcut}
									onView={(v) => {
										editorViewRef.current = v;
										// The view existing is the first moment content is on
										// screen. Delta from open:resolved is the CodeMirror
										// construction cost, and on the first open of a page
										// load it also carries the lazy chunk fetch (#1317).
										if (v && shownId) {
											crdtMark(shownId, "editor:construct-end");
											if (handle && handle.ytext.length === 0) {
												crdtMark(shownId, "editor:seeded-empty");
											}
										}
									}}
								/>
							) : (
								<p className="p-5 text-muted-foreground">Connecting…</p>
							)}
						</Suspense>
					)}
				</div>
			</ScrollArea>

			{dialog === "move" ? (
				<MoveDialog
					folders={folders ?? []}
					nodes={[{ kind: "file", path: note.path }]}
					onPick={(folder) => {
						setDialog(null);
						batchMoveNotes.mutate({
							ids: [note.id],
							target_folder: folder,
							paths: { [note.id]: note.path },
						});
					}}
					onCancel={() => setDialog(null)}
				/>
			) : null}

			{dialog === "delete" ? (
				<DeleteConfirm
					nodes={[{ kind: "file", path: note.path }]}
					onConfirm={() => {
						setDialog(null);
						deleteNote.mutate({ id: note.id, path: note.path });
						// useDeleteNote does not navigate — from the tree the deleted note
						// usually isn't open, but here it is, so staying would strand the
						// user on a dead route.
						navigate(slug ? vaultPath(slug) : "/");
					}}
					onCancel={() => setDialog(null)}
				/>
			) : null}
		</section>
	);
}
