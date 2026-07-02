import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { useFolders } from "@/api/queries";
import { useDemoVaultOptional } from "../../onboarding/tour/demo-vault-provider";
import { AttachmentUploadDialog } from "./upload-dialog";

interface UploadApi {
	// defaultFolder pre-selects the dialog's destination (e.g. the folder the user
	// is browsing); omit for vault root.
	openUpload: (files?: File[], defaultFolder?: string) => void;
}

const Ctx = createContext<UploadApi | null>(null);

function hasFiles(e: DragEvent): boolean {
	return Array.from(e.dataTransfer?.types ?? []).includes("Files");
}

export function useAttachmentUpload(): UploadApi {
	const v = useContext(Ctx);
	if (!v) {
		throw new Error("useAttachmentUpload must be used within AttachmentUploadProvider");
	}
	return v;
}

export function AttachmentUploadProvider({ children }: { children: React.ReactNode }) {
	const [files, setFiles] = useState<File[] | null>(null); // null = dialog closed
	const [pendingFolder, setPendingFolder] = useState(""); // default dest for the next dialog
	const [dragging, setDragging] = useState(false);
	const depth = useRef(0);
	const pickerRef = useRef<HTMLInputElement>(null);
	const folders = useFolders().data ?? [];
	// Demo vaults are read-only previews (mirrors useAttachments); uploading would
	// POST to the real backend with the demo vault's id. Gate the whole flow off.
	const demoActive = useDemoVaultOptional()?.active === true;

	// No files → open the OS picker (the dialog opens once files are chosen, so
	// the button never flashes an empty dialog). Files present → open directly.
	const openUpload = useCallback(
		(dropped?: File[], defaultFolder = "") => {
			if (demoActive) {
				return;
			}
			setPendingFolder(defaultFolder);
			if (dropped && dropped.length > 0) {
				setFiles(dropped);
			} else {
				pickerRef.current?.click();
			}
		},
		[demoActive],
	);

	// Window-level drag handling. The hasFiles() guard means INTERNAL headless-tree
	// note/folder drags (which carry no 'Files' type) never trip the overlay — the
	// single most important invariant of this feature. Demo vaults register no
	// listeners at all, so the overlay never appears mid-tour.
	useEffect(() => {
		if (demoActive) {
			return;
		}
		const onEnter = (e: DragEvent) => {
			if (!hasFiles(e)) {
				return;
			}
			e.preventDefault();
			depth.current += 1;
			setDragging(true);
		};
		const onOver = (e: DragEvent) => {
			if (!hasFiles(e)) {
				return;
			}
			e.preventDefault(); // required so 'drop' fires
		};
		const onLeave = (e: DragEvent) => {
			if (!hasFiles(e)) {
				return;
			}
			depth.current -= 1;
			if (depth.current <= 0) {
				depth.current = 0;
				setDragging(false);
			}
		};
		const onDrop = (e: DragEvent) => {
			if (!hasFiles(e)) {
				return;
			}
			e.preventDefault();
			depth.current = 0;
			setDragging(false);
			const dropped = Array.from(e.dataTransfer?.files ?? []);
			if (dropped.length > 0) {
				// A whole-window drop has no folder context — default to vault root.
				setPendingFolder("");
				setFiles(dropped);
			}
		};
		window.addEventListener("dragenter", onEnter);
		window.addEventListener("dragover", onOver);
		window.addEventListener("dragleave", onLeave);
		window.addEventListener("drop", onDrop);
		return () => {
			window.removeEventListener("dragenter", onEnter);
			window.removeEventListener("dragover", onOver);
			window.removeEventListener("dragleave", onLeave);
			window.removeEventListener("drop", onDrop);
		};
	}, [demoActive]);

	return (
		<Ctx.Provider value={{ openUpload }}>
			{children}
			<input
				ref={pickerRef}
				type="file"
				multiple
				hidden
				onChange={(e) => {
					const picked = Array.from(e.target.files ?? []);
					e.target.value = "";
					if (picked.length > 0) {
						setFiles(picked);
					}
				}}
			/>
			{Boolean(dragging) && (
				<div
					aria-hidden
					className="fixed inset-0 z-50 flex items-center justify-center bg-blue-500/10 ring-2 ring-blue-400 ring-inset backdrop-blur-sm"
				>
					<p className="rounded-lg bg-card px-6 py-4 font-medium text-lg shadow-xl">
						Drop files to upload
					</p>
				</div>
			)}
			{files !== null && (
				<AttachmentUploadDialog
					initialFiles={files}
					folders={folders.map((f) => ({ name: f.name }))}
					defaultFolder={pendingFolder}
					onClose={() => setFiles(null)}
				/>
			)}
		</Ctx.Provider>
	);
}
