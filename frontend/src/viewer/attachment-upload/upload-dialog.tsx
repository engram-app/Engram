import { useRef, useState } from "react";
import { useUploadAttachment } from "@/api/queries";
import { useUpgradeDialog } from "@/billing/upgrade-dialog-provider";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useConfig } from "@/config-context";
import { useT } from "@/i18n/locale-provider";
import type { Translate } from "@/i18n/translate";
import { FolderPicker } from "./folder-picker";
import { type UploadFailure, uploadFailure } from "./upload-failure";

// "waiting" = the upload layer is backing off before a retry; not a failure.
type RowStatus = "pending" | "uploading" | "waiting" | "done" | "error";
interface Row {
	file: File;
	status: RowStatus;
	error?: UploadFailure;
	/** 0-100 for a parts upload; undefined = indeterminate (single request). */
	pct?: number;
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

function statusText(row: Row, t: Translate): string {
	switch (row.status) {
		case "error":
			return row.error?.text ?? "";
		case "uploading":
			return t("Uploading…");
		case "waiting":
			return t("Waiting to retry");
		case "done":
			return t("Done");
		default:
			return t("{size} · {type}", {
				size: humanSize(row.file.size),
				type: row.file.type || t("unknown"),
			});
	}
}

const patch = (rows: Row[], i: number, next: Partial<Row>): Row[] =>
	rows.map((row, idx) => (idx === i ? { ...row, ...next } : row));

export function AttachmentUploadDialog({ initialFiles, folders, defaultFolder, onClose }: Props) {
	const { t } = useT();
	const [rows, setRows] = useState<Row[]>(() =>
		initialFiles.map((file): Row => ({ file, status: "pending" })),
	);
	const [folder, setFolder] = useState(defaultFolder ?? ""); // '' = vault root
	const [busy, setBusy] = useState(false);
	const addRef = useRef<HTMLInputElement>(null);
	const upload = useUploadAttachment();
	const { billingEnabled } = useConfig();
	const { showUpgrade } = useUpgradeDialog();

	async function uploadRow(i: number) {
		const row = rows[i];
		if (!row || row.status === "done") {
			return;
		}
		setRows((r) => patch(r, i, { status: "uploading", error: undefined, pct: undefined }));
		try {
			const path = folder ? `${folder}/${row.file.name}` : row.file.name;
			await upload.mutateAsync({
				path,
				file: row.file,
				onProgress: (done, total) =>
					setRows((r) =>
						patch(r, i, { status: "uploading", pct: Math.floor((done / total) * 100) }),
					),
				onRetry: () => setRows((r) => patch(r, i, { status: "waiting" })),
			});
			setRows((r) => patch(r, i, { status: "done", pct: undefined }));
		} catch (err) {
			setRows((r) =>
				patch(r, i, { status: "error", error: uploadFailure(err, t), pct: undefined }),
			);
		}
	}

	async function commit() {
		setBusy(true);
		// Each file uploads independently so one failure never aborts the rest
		// (partial success is first-class).
		try {
			for (const i of rows.keys()) {
				await uploadRow(i);
			}
		} finally {
			// setBusy in finally so it always runs even if a mid-loop upload throws.
			setBusy(false);
		}
	}

	async function retryRow(i: number) {
		setBusy(true);
		try {
			await uploadRow(i);
		} finally {
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
					<DialogTitle className="text-sm">{t("Upload attachments")}</DialogTitle>
					<Button variant="ghost" size="sm" onClick={onClose}>
						{t("Close")}
					</Button>
				</header>

				{folders.length > 0 && (
					<section className="flex min-h-0 flex-1 flex-col px-4 py-3">
						<h3 className="mb-2 font-semibold text-base text-foreground">
							{t("Destination folder")}
						</h3>
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
						{rows.map((row, i) => (
							<li
								key={`${row.file.name}-${row.file.size}-${row.file.lastModified}`}
								className="flex items-center justify-between border-border/50 border-b py-1.5 text-sm last:border-b-0"
							>
								<span className="truncate">{row.file.name}</span>
								<span className="ml-2 flex shrink-0 items-center gap-2 text-muted-foreground text-xs">
									{/* Only the status text is announced; the controls stay outside the live region. */}
									<output className={row.status === "error" ? "text-destructive" : undefined}>
										{statusText(row, t)}
									</output>
									{row.status === "uploading" || row.status === "waiting" ? (
										<>
											<progress
												aria-label={t("Uploading {name}", { name: row.file.name })}
												value={row.pct}
												max={100}
											/>
											{row.pct === undefined ? null : t("{pct}%", { pct: row.pct })}
										</>
									) : null}
									{row.status === "error" &&
									row.error?.upgradeReason !== undefined &&
									billingEnabled ? (
										<Button
											variant="link"
											size="sm"
											onClick={() => showUpgrade(row.error?.upgradeReason ?? "")}
										>
											{t("Upgrade")}
										</Button>
									) : null}
									{row.status === "error" && row.error?.retry ? (
										<Button variant="link" size="sm" disabled={busy} onClick={() => retryRow(i)}>
											{t("Try again")}
										</Button>
									) : null}
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
					<Button variant="outline" onClick={() => addRef.current?.click()} disabled={busy}>
						{t("Upload more")}
					</Button>
					{allDone ? (
						<Button onClick={onClose}>{t("Done")}</Button>
					) : (
						<Button onClick={commit} disabled={busy || rows.length === 0}>
							{t("Upload")}
						</Button>
					)}
				</footer>
			</DialogContent>
		</Dialog>
	);
}
