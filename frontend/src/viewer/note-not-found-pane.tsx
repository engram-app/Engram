import { FileQuestion } from "lucide-react";
import { heading } from "@/lib/ui-classes";
import { DocumentSurface } from "./document-surface";

// In-pane "no such note" state, for a URL whose note id can't name a note
// (malformed or truncated). NOT the full-page 404: it renders inside the app
// shell on the document surface, so the sidebar stays usable and no navigation
// is offered — the user is already in their vault.
export default function NoteNotFoundPane() {
	return (
		<DocumentSurface>
			<div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
				<FileQuestion aria-hidden className="size-10 text-muted-foreground" />
				<h1 className={heading}>Note not found</h1>
				<p className="text-muted-foreground text-sm">This note may have been moved or deleted.</p>
			</div>
		</DocumentSurface>
	);
}
