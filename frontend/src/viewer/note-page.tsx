import type { EditorView } from "@codemirror/view";
import { BookOpen, Pencil } from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocation, useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import type { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
	useBatchMoveNotes,
	useDeleteNote,
	useDuplicateNote,
	useFolders,
	useNote,
	useRenameNote,
} from "../api/queries";
import { readRows } from "../crdt/frontmatter-doc";
import {
	type CrdtSyncStatus,
	closeDoc,
	enroll,
	getCrdtSyncStatus,
	openDoc,
	subscribeToCrdtSyncStatus,
} from "../crdt/session";
import { useRightTools } from "../layout/right-tools-context";
import { copyToClipboard } from "../lib/clipboard";
import { noteName } from "../lib/note-name";
import { useActiveEditor } from "./editor/active-editor-context";
import { RawFrontmatterEditor } from "./editor/raw-frontmatter-editor";
import { InlineTitle } from "./inline-title";
import LoadingPane from "./loading-pane";
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

const NoteEditor = lazy(() => import("./note-editor"));

interface DocHandle {
	ytext: Y.Text;
	awareness: Awareness;
	doc: Y.Doc;
}

export default function NotePage() {
	const { itemId: idStr, slug } = useParams();
	const validId = idStr && idStr.length > 0 ? idStr : null;

	const { data: note, isLoading, error } = useNote(validId);
	const { setSlot } = useRightTools();
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
	const renamingAt = renaming && renaming.id === note?.id ? renaming.at : null;
	const [handle, setHandle] = useState<DocHandle | null>(null);
	const renameNote = useRenameNote();
	const [syncStatus, setSyncStatus] = useState<CrdtSyncStatus>(getCrdtSyncStatus);
	const editorViewRef = useRef<EditorView | null>(null);
	// Same lookup NoteView builds for its remark-wiki-link hrefTemplate — a
	// resolved link routes straight to the note id instead of through the
	// lazy /:slug/wiki/* resolver.
	const wikiMap = useMemo(() => buildWikiMap(note?.links), [note?.links]);
	// useCallback keeps a stable identity so passing it to NoteEditor doesn't
	// re-fire the decorationsCompartment reconfigure effect on every render.
	const resolveWikiLink = useCallback(
		(permalink: string) => wikiHref(permalink, slug, wikiMap),
		[slug, wikiMap],
	);
	// Editor-mode click-to-open. Router nav must come from the React tree —
	// see LivePreviewOpts.openWikiLink for why the editor can't reach the
	// router singleton itself.
	const openWikiLink = useCallback(
		(permalink: string) => {
			const href = wikiHref(permalink, slug, wikiMap);
			if (href.startsWith("/")) {
				void navigate(href);
			} else if (href.startsWith("#")) {
				// Same-page heading — hash assignment scrolls, no reload.
				window.location.hash = href;
			}
		},
		[navigate, slug, wikiMap],
	);

	const path = note?.path ?? null;
	const noteId = note?.id ?? null;
	// CRDT manages MARKDOWN only — mirrors the server-side `.md` gate
	// (crdt_deliver.ex). note_id carries no extension, so the check has to
	// happen here, at the one call site that still has the current path.
	const isMarkdown = path?.endsWith(".md") ?? false;

	// Open the CRDT doc on .md note mount, keyed by the note's stable note_id
	// (NOT path — a rename/move must not tear down and rebuild the live doc);
	// enroll for the STEP1 handshake; close on note switch / unmount. yCollab
	// (in NoteEditor) owns convergence — there is no REST autosave, 3-way
	// merge, or conflict UI on this path anymore.
	useEffect(() => {
		if (!(noteId && isMarkdown)) {
			return;
		}
		let cancelled = false;
		openDoc(noteId).then((h) => {
			if (cancelled || !h) {
				return;
			}
			setHandle(h);
			enroll(noteId);
		});
		return () => {
			cancelled = true;
			setHandle(null);
			closeDoc(noteId);
		};
	}, [noteId, isMarkdown]);

	// Subscribe to CRDT sync status changes (non-blocking -- editor still works offline).
	useEffect(() => subscribeToCrdtSyncStatus(setSyncStatus), []);

	// Signal the onboarding tour that the user opened a note.
	useEffect(() => {
		if (!note?.path) {
			return;
		}
		window.dispatchEvent(new CustomEvent("engram:note-opened", { detail: { path: note.path } }));
	}, [note?.path]);

	// ToC reads the materialized REST content (refreshed by note_changed).
	// Hoist the two primitives the effect actually depends on so the captured
	// values match the dependency list (a new `note` object identity each
	// render would otherwise rebuild the ToC needlessly).
	const notePath = note?.path;
	const noteContent = note?.content;
	const liveContent = useLiveContent(handle?.ytext ?? null, noteContent ?? "");
	useEffect(() => {
		if (notePath === undefined) {
			setSlot("outline", null);
			return;
		}
		setSlot("outline", <NoteToc content={liveContent} />);
		return () => setSlot("outline", null);
	}, [notePath, liveContent, setSlot]);

	// Consume the just-created flag exactly once: start renaming, then strip the
	// state so a later back-navigation to this history entry doesn't reopen the
	// rename box on a note the user already named.
	const location = useLocation();
	const justCreated = Boolean((location.state as { justCreated?: boolean } | null)?.justCreated);
	useEffect(() => {
		if (!(justCreated && noteId)) {
			return;
		}
		setRenaming({ id: noteId, at: "title" });
		navigate(location.pathname, { replace: true, state: {} });
	}, [justCreated, noteId, navigate, location.pathname]);

	// The draft belongs to the note you are looking at, not to the page, which
	// stays mounted across note switches. Adjusted during render rather than in
	// an effect — React's documented pattern for resetting state on a prop
	// change, and it avoids rendering the stale draft for one frame.
	const [draftNoteId, setDraftNoteId] = useState(noteId);
	if (draftNoteId !== noteId) {
		setDraftNoteId(noteId);
		setFrontmatterDraft(false);
	}

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

	if (validId === null) {
		return <p className="p-6 text-destructive">Invalid note id.</p>;
	}
	if (isLoading) {
		return <LoadingPane />;
	}
	if (error) {
		return <p className="p-6 text-destructive">Failed to load note: {error.message}</p>;
	}
	if (!note) {
		return <p className="p-6 text-muted-foreground">Note not found</p>;
	}

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
		<section className="mx-auto flex h-full min-h-0 w-full min-w-0 max-w-[840px] flex-col overflow-hidden border-border border-x bg-card text-card-foreground md:-my-6 md:h-[calc(100%+3rem)]">
			{syncStatus === "error" && (
				<p role="status" className="shrink-0 bg-destructive/10 px-4 py-1 text-destructive text-xs">
					Not syncing - reconnecting...
				</p>
			)}
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

			{/* EditorToolbar is deliberately NOT mounted — see editor/toolbar.tsx.
			    A desktop-width strip of format buttons earns little next to the
			    markdown shortcuts, and the case it does earn is mobile, where it
			    belongs above the keyboard rather than under the header. */}

			<ScrollArea className="min-h-0 flex-1">
				<div className="w-full pb-5" data-tour="note-editor">
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
							<NoteView content={liveContent} tags={note.tags} links={note.links} />
						</div>
					) : (
						<Suspense fallback={<p className="px-5 py-5 text-muted-foreground">Loading editor…</p>}>
							{handle ? (
								<NoteEditor
									ytext={handle.ytext}
									awareness={handle.awareness}
									mode={mode === "raw" ? "raw" : "rendered"}
									resolveWikiLink={resolveWikiLink}
									openWikiLink={openWikiLink}
									onFrontmatterShortcut={handleFrontmatterShortcut}
									onView={(v) => {
										editorViewRef.current = v;
									}}
								/>
							) : (
								<p className="px-5 py-5 text-muted-foreground">Connecting…</p>
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
						navigate(slug ? `/${slug}` : "/");
					}}
					onCancel={() => setDialog(null)}
				/>
			) : null}
		</section>
	);
}
