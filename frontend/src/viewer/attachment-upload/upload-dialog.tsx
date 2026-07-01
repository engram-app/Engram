import { useRef, useState } from "react";
import { ApiError, LimitExceededError } from "@/api/client";
import { useUploadAttachment } from "@/api/queries";
import { Button } from "@/components/ui/button";
import { fileToBase64 } from "./file-to-base64";

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

function messageFor(err: unknown): string {
	if (isLimitExceededError(err)) {
		switch ((err as LimitExceededError).reason) {
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
	if (err instanceof ApiError || (err instanceof Error && err.name === "ApiError")) {
		const apiErr = err as ApiError;
		if (apiErr.status === 415) {
			return "This file type is not allowed";
		}
		return apiErr.message || "Upload failed";
	}
	return "Upload failed";
}

const patch = (rows: Row[], i: number, next: Partial<Row>): Row[] =>
	rows.map((row, idx) => (idx === i ? { ...row, ...next } : row));

const optionId = (i: number): string => `upload-folder-opt-${i}`;

export function AttachmentUploadDialog({ initialFiles, folders, defaultFolder, onClose }: Props) {
	const [rows, setRows] = useState<Row[]>(() =>
		initialFiles.map((file) => ({ file, status: "pending" as RowStatus })),
	);
	const [folder, setFolder] = useState(defaultFolder ?? ""); // '' = vault root
	const [busy, setBusy] = useState(false);
	const addRef = useRef<HTMLInputElement>(null);
	const upload = useUploadAttachment();

	// Root first, then real folders.
	const candidates = ["", ...folders.map((f) => f.name)];
	// Index of the selected option — drives aria-activedescendant + arrow-key nav.
	const activeIndex = Math.max(0, candidates.indexOf(folder));

	// Listbox keyboard support (selection follows focus): arrows + Home/End move
	// the selection so the picker is operable without a mouse.
	function onFolderKeyDown(e: React.KeyboardEvent) {
		let next = activeIndex;
		if (e.key === "ArrowDown") {
			next = Math.min(activeIndex + 1, candidates.length - 1);
		} else if (e.key === "ArrowUp") {
			next = Math.max(activeIndex - 1, 0);
		} else if (e.key === "Home") {
			next = 0;
		} else if (e.key === "End") {
			next = candidates.length - 1;
		} else {
			return;
		}
		e.preventDefault();
		setFolder(candidates[next] ?? "");
	}

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
			setRows((r) => [...r, ...more.map((file) => ({ file, status: "pending" as RowStatus }))]);
		}
	}

	const allDone = rows.length > 0 && rows.every((r) => r.status === "done");

	return (
		<dialog
			open
			aria-label="Upload attachments"
			className="fixed inset-0 z-50 m-auto h-[28rem] w-[32rem] rounded-lg bg-card p-0 shadow-xl"
		>
			<header className="flex items-center justify-between border-border border-b px-4 py-3">
				<h2 className="font-semibold text-sm">Upload attachments</h2>
				<Button variant="ghost" size="sm" onClick={onClose}>
					Close
				</Button>
			</header>

			{candidates.length > 1 && (
				<section className="px-4 py-3">
					<span className="mb-1 block font-medium text-muted-foreground text-xs">
						Destination folder
					</span>
					<div
						role="listbox"
						aria-label="Destination folder"
						tabIndex={0}
						aria-activedescendant={optionId(activeIndex)}
						onKeyDown={onFolderKeyDown}
						className="max-h-24 overflow-y-auto rounded border border-border focus:outline-none focus:ring-2 focus:ring-blue-400"
					>
						{candidates.map((name, i) => (
							// biome-ignore lint/a11y/useFocusableInteractive lint/a11y/useKeyWithClickEvents: option in an aria-activedescendant listbox; options are intentionally not individually focusable and keyboard activation is handled on the listbox container above
							<div
								key={name || "__root__"}
								id={optionId(i)}
								role="option"
								aria-selected={name === folder}
								onClick={() => setFolder(name)}
								className={`cursor-pointer px-3 py-1 text-sm ${name === folder ? "bg-blue-50 dark:bg-blue-950" : ""}`}
							>
								{name === "" ? "/ (root)" : `${name}`}
							</div>
						))}
					</div>
				</section>
			)}

			<ul className="max-h-40 overflow-y-auto px-4">
				{rows.map((row) => (
					<li
						key={`${row.file.name}-${row.file.size}-${row.file.lastModified}`}
						className="flex items-center justify-between border-border/50 border-b py-1.5 text-sm"
					>
						<span className="truncate">{row.file.name}</span>
						<span className="ml-2 shrink-0 text-muted-foreground text-xs">
							{row.status === "error" ? (
								<span className="text-red-600 dark:text-red-400">{row.error}</span>
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
					Add files
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
		</dialog>
	);
}
