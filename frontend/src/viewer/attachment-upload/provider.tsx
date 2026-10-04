import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { useAttachments, useFolders, useUploadAttachment } from "@/api/queries";
import { useT } from "@/i18n/locale-provider";
import { AttachmentUploadDialog } from "./upload-dialog";
import { uploadFilesTo } from "./upload-files";

interface UploadApi {
	// The Upload button's path: opens the OS picker, then the dialog to choose a
	// destination. defaultFolder pre-selects it (e.g. the folder the user is
	// browsing); omit for vault root.
	openUpload: (files?: File[], defaultFolder?: string) => void;
	// The drop path: upload straight into `folder` ("" = root), no dialog.
	uploadFiles: (files: File[], folder: string) => Promise<void>;
}

const Ctx = createContext<UploadApi | null>(null);

function hasFiles(e: DragEvent): boolean {
	return Array.from(e.dataTransfer?.types ?? []).includes("Files");
}

// Elements that take file drops themselves (the note text, the file tree). Mark
// one with `data-file-drop`.
function overFileDropTarget(e: DragEvent): boolean {
	return e.target instanceof Element && e.target.closest("[data-file-drop]") !== null;
}

export function useAttachmentUpload(): UploadApi {
	const v = useContext(Ctx);
	if (!v) {
		throw new Error("useAttachmentUpload must be used within AttachmentUploadProvider");
	}
	return v;
}

/** `uploadFiles` for drop targets, or null outside the provider (unit tests). */
export function useFileDropUpload(): UploadApi["uploadFiles"] | null {
	return useContext(Ctx)?.uploadFiles ?? null;
}

export function AttachmentUploadProvider({ children }: { children: React.ReactNode }) {
	const { t, tn } = useT();
	const [files, setFiles] = useState<File[] | null>(null); // null = dialog closed
	const [pendingFolder, setPendingFolder] = useState(""); // default dest for the next dialog
	const pickerRef = useRef<HTMLInputElement>(null);
	const folders = useFolders().data ?? [];
	const attachments = useAttachments().data;
	const upload = useUploadAttachment();

	// No files → open the OS picker (the dialog opens once files are chosen, so
	// the button never flashes an empty dialog). Files present → open directly.
	const openUpload = useCallback((dropped?: File[], defaultFolder = "") => {
		setPendingFolder(defaultFolder);
		if (dropped && dropped.length > 0) {
			setFiles(dropped);
		} else {
			pickerRef.current?.click();
		}
	}, []);

	const uploadFiles = useCallback(
		async (dropped: File[], folder: string) => {
			const done = await uploadFilesTo({
				upload: upload.mutateAsync,
				existing: attachments ?? [],
				files: dropped,
				folder,
				t,
			});
			if (done.length === 1) {
				const name = done[0]?.split("/").pop() ?? t("file");
				toast.success(
					folder
						? t("Uploaded {name} to {folder}", { name, folder })
						: t("Uploaded {name}", { name }),
				);
			} else if (done.length > 1) {
				toast.success(
					folder
						? tn(
								{
									one: "Uploaded {count} file to {folder}",
									other: "Uploaded {count} files to {folder}",
								},
								done.length,
								{ folder },
							)
						: tn({ one: "Uploaded {count} file", other: "Uploaded {count} files" }, done.length),
				);
			}
		},
		[upload.mutateAsync, attachments, t, tn],
	);

	// A file dropped anywhere that is not a drop target does nothing, and must not
	// fall through to the browser opening it in place of the app. The drop cursor
	// shows "not allowed" there. The dialog is the Upload button's, never a drop's.
	useEffect(() => {
		const onOver = (e: DragEvent) => {
			if (!hasFiles(e) || overFileDropTarget(e)) {
				return;
			}
			e.preventDefault();
			if (e.dataTransfer) {
				e.dataTransfer.dropEffect = "none";
			}
		};
		const onDrop = (e: DragEvent) => {
			if (hasFiles(e)) {
				e.preventDefault();
			}
		};
		window.addEventListener("dragover", onOver);
		window.addEventListener("drop", onDrop);
		return () => {
			window.removeEventListener("dragover", onOver);
			window.removeEventListener("drop", onDrop);
		};
	}, []);

	return (
		<Ctx.Provider value={{ openUpload, uploadFiles }}>
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
