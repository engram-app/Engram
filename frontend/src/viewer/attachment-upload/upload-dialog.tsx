import { useRef, useState } from "react";
import { ApiError, LimitExceededError } from "@/api/client";
import { useUploadAttachment } from "@/api/queries";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { fileToBase64 } from "./file-to-base64";
import { FolderPicker } from "./folder-picker";

type RowStatus = "pending" | "uploading" | "done" | "error";
interface Row {
	file: File;
	status: RowStatus;
	error?: string;
}

interface Props {
	initialFiles: File[];
	folders: { name: string }[];
	// Pre-selected destination (e.g. the folder the user is browsing); '' = root.
	defaultFolder?: string;
	onClose: () => void;
}

function humanSize(bytes: number): string {
	if (bytes < 1024) {
		return `${bytes} B`;
	}
	if (bytes < 1024 * 1024) {
		return `${(bytes / 1024).toFixed(1)} KB`;
	}
	return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function isLimitExceededError(err: unknown): err is LimitExceededError {
	return (
		err instanceof LimitExceededError || (err instanceof Error && err.name === "LimitExceededError")
	);
}

function isApiError(err: unknown): err is ApiError {
	return err instanceof ApiError || (err instanceof Error && err.name === "ApiError");
}

function messageFor(err: unknown): string {
	if (isLimitExceededError(err)) {
		switch (err.reason) {
			case "attachments_disabled":
				return "Upgrade to upload attachments";
			case "attachment_must_be_text":
				return "Free tier: text files only";
			case "file_too_large":
				return "File exceeds your plan's size limit";
			case "attachments_quota_exceeded":
				return "Storage quota reached";
			default:
				return "Upgrade required";
		}
	}
	if (isApiError(err)) {
		if (err.status === 415) {
			return "This file type is not allowed";
		}
		return err.message || "Upload failed";
	}
	return "Upload failed";
}

const patch = (rows: Row[], i: number, next: Partial<Row>): Row[] =>
	rows.map((row, idx) => (idx === i ? { ...row, ...next } : row));

export function AttachmentUploadDialog({ initialFiles, folders, defaultFolder, onClose }: Props) {
	const [rows, setRows] = useState<Row[]>(() =>
		initialFiles.map((file): Row => ({ file, status: "pending" })),
	);
	const [folder, setFolder] = useState(defaultFolder ?? ""); // '' = vault root
	const [busy, setBusy] = useState(false);
	const addRef = useRef<HTMLInputElement>(null);
	const upload = useUploadAttachment();

	async function commit() {
		setBusy(true);
		// Each file uploads independently so one failure never aborts the rest
		// (partial success is first-class).
		try {
			for (const [i, row] of rows.entries()) {
				if (row.status === "done") {
					continue;
				}
				setRows((r) => patch(r, i, { status: "uploading", error: undefined }));
				try {
					const content_base64 = await fileToBase64(row.file);
					const path = folder ? `${folder}/${row.file.name}` : row.file.name;
					await upload.mutateAsync({
						path,
						mime_type: row.file.type || undefined,
						content_base64,
						mtime: Math.floor(row.file.lastModified / 1000),
					});
					setRows((r) => patch(r, i, { status: "done" }));
				} catch (err) {
					setRows((r) => patch(r, i, { status: "error", error: messageFor(err) }));
				}
			}
		} finally {
			// setBusy in finally so it always runs even if a mid-loop upload throws.
			setBusy(false);
		}
	}

	function addFiles(picked: FileList | null) {
		const more = Array.from(picked ?? []);
		if (more.length > 0) {
			setRows((r) => [...r, ...more.map((file): Row => ({ file, status: "pending" }))]);
		}
	}

	const allDone = rows.length > 0 && rows.every((r) => r.status === "done");

	return (
		<Dialog open onOpenChange={(open) => !open && onClose()}>
			<DialogContent
				aria-describedby={undefined}
				showCloseButton={false}
				className="flex h-[min(36rem,85vh)] max-w-xl flex-col gap-0 p-0 sm:max-w-xl"
			>
				<header className="flex items-center justify-between border-border border-b px-4 py-3">
					<DialogTitle className="text-sm">Upload attachments</DialogTitle>
					<Button variant="ghost" size="sm" onClick={onClose}>
						Close
					</Button>
				</header>

				{folders.length > 0 && (
					<section className="flex min-h-0 flex-1 flex-col px-4 py-3">
						<h3 className="mb-2 font-semibold text-base text-foreground">Destination folder</h3>
						<FolderPicker
							folders={folders.map((f) => f.name)}
							value={folder}
							onChange={setFolder}
							className="flex-1"
						/>
					</section>
				)}

				<ScrollArea className="shrink-0 border-border border-t" viewportClassName="max-h-40">
					<ul className="px-4">
						{rows.map((row) => (
							<li
								key={`${row.file.name}-${row.file.size}-${row.file.lastModified}`}
								className="flex items-center justify-between border-border/50 border-b py-1.5 text-sm last:border-b-0"
							>
								<span className="truncate">{row.file.name}</span>
								<span className="ml-2 shrink-0 text-muted-foreground text-xs">
									{row.status === "error" ? (
										<span className="text-destructive">{row.error}</span>
									) : row.status === "uploading" ? (
										"Uploading…"
									) : row.status === "done" ? (
										"Done"
									) : (
										`${humanSize(row.file.size)} · ${row.file.type || "unknown"}`
									)}
								</span>
							</li>
						))}
					</ul>
				</ScrollArea>

				<footer className="flex items-center justify-end gap-2 border-border border-t px-4 py-3">
					<input
						ref={addRef}
						type="file"
						multiple
						hidden
						onChange={(e) => {
							addFiles(e.target.files);
							e.target.value = "";
						}}
					/>
					<Button variant="ghost" size="sm" onClick={() => addRef.current?.click()} disabled={busy}>
						Upload more
					</Button>
					{allDone ? (
						<Button size="sm" onClick={onClose}>
							Done
						</Button>
					) : (
						<Button size="sm" onClick={commit} disabled={busy || rows.length === 0}>
							Upload
						</Button>
					)}
				</footer>
			</DialogContent>
		</Dialog>
	);
}
