import { lazy, Suspense, useEffect, useState } from "react";
import { useParams } from "react-router";
import type { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useNote } from "../api/queries";
import {
	type CrdtSyncStatus,
	closeDoc,
	enroll,
	getCrdtSyncStatus,
	openDoc,
	subscribeToCrdtSyncStatus,
} from "../crdt/session";
import { useRightSidebar } from "../layout/right-sidebar-context";
import LoadingPane from "./loading-pane";
import NoteToc from "./note-toc";
import NoteView from "./note-view";
import { PropertiesWidget } from "./properties-widget";
import { useLiveContent } from "./use-live-content";

const NoteEditor = lazy(() => import("./note-editor"));

type Mode = "live" | "reading";
interface DocHandle {
	ytext: Y.Text;
	awareness: Awareness;
	doc: Y.Doc;
}

export default function NotePage() {
	const params = useParams();
	const idStr = params.id;
	const validId = idStr && idStr.length > 0 ? idStr : null;

	const { data: note, isLoading, error } = useNote(validId);
	const { setContent: setRightContent } = useRightSidebar();

	const [mode, setMode] = useState<Mode>("live");
	const [handle, setHandle] = useState<DocHandle | null>(null);
	const [syncStatus, setSyncStatus] = useState<CrdtSyncStatus>(getCrdtSyncStatus);

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
			setRightContent(null);
			return;
		}
		setRightContent(<NoteToc content={liveContent} />);
		return () => setRightContent(null);
	}, [notePath, liveContent, setRightContent]);

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

	const titlePath = note.folder ? `${note.folder}/${note.title}` : note.title;

	return (
		<section className="mx-auto flex h-full min-h-0 w-full min-w-0 max-w-[840px] flex-col overflow-hidden border-border border-x bg-card text-card-foreground md:-my-6 md:h-[calc(100%+3rem)]">
			{syncStatus === "error" && (
				<p role="status" className="shrink-0 bg-destructive/10 px-4 py-1 text-destructive text-xs">
					Not syncing - reconnecting...
				</p>
			)}
			<div className="flex shrink-0 items-center gap-2 border-border border-b px-4 py-2">
				<h2 className="flex min-w-0 flex-1 items-baseline gap-1 text-sm" title={titlePath}>
					{Boolean(note.folder) && (
						<span className="min-w-0 shrink truncate text-muted-foreground">{note.folder}/</span>
					)}
					<span className="min-w-0 truncate font-medium">{note.title}</span>
				</h2>
				<Button
					variant="ghost"
					size="sm"
					className="shrink-0"
					onClick={() => setMode((m) => (m === "live" ? "reading" : "live"))}
				>
					{mode === "live" ? "↗ Reading view" : "✎ Edit"}
				</Button>
			</div>

			{handle ? <PropertiesWidget doc={handle.doc} /> : null}

			{mode === "reading" ? (
				<ScrollArea className="min-h-0 flex-1">
					<div className="w-full px-5 py-5">
						<NoteView content={liveContent} tags={note.tags} />
					</div>
				</ScrollArea>
			) : (
				<div className="min-h-0 flex-1 overflow-hidden" data-tour="note-editor">
					<Suspense fallback={<p className="py-5 text-muted-foreground">Loading editor…</p>}>
						{handle ? (
							<NoteEditor ytext={handle.ytext} awareness={handle.awareness} />
						) : (
							<p className="py-5 text-muted-foreground">Connecting…</p>
						)}
					</Suspense>
				</div>
			)}
		</section>
	);
}
