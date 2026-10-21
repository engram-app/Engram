import {
	Download,
	ExternalLink,
	File,
	FileArchive,
	FileAudio,
	FileCode,
	FileImage,
	FileSpreadsheet,
	FileText,
	FileVideo,
	FolderInput,
	type LucideIcon,
	Shapes,
	TextCursorInput,
	Trash2,
} from "lucide-react";
import { useState } from "react";
import { useNavigate, useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { formatDate } from "@/lib/format-date";
import { intlLocale } from "@/lib/intl-locale";
import { cn } from "@/lib/utils";
import {
	type AttachmentSummary,
	useBatchDeleteAttachments,
	useBatchMoveAttachments,
	useFolders,
	useRenameAttachment,
} from "../api/queries";
import { vaultRootHref } from "../routes";
import {
	attachmentRenamePath,
	fileStem,
	formatBytes,
	type PreviewKind,
} from "./attachment-preview";
import { DeleteConfirm } from "./tree-actions/delete-confirm";
import { MoveDialog } from "./tree-actions/move-dialog";
import { RenameInput } from "./tree-actions/rename-input";

const ARCHIVE = /\.(?:zip|7z|rar|tar|gz|tgz|bz2|xz|zst)$/iu;

const KIND_ICONS: Record<PreviewKind, LucideIcon> = {
	image: FileImage,
	pdf: FileText,
	audio: FileAudio,
	video: FileVideo,
	csv: FileSpreadsheet,
	text: FileCode,
	excalidraw: Shapes,
};

interface NameProps {
	path: string;
	editing: boolean;
	onEdit: () => void;
	onDone: () => void;
	/** Classes for the clickable name; the header and the title differ. */
	className: string;
}

interface Props {
	att: AttachmentSummary;
	kind: PreviewKind | null;
	/** Set once the bytes are in memory; Open in new tab needs it. */
	inlineUrl: string | null;
	onDownload: () => void;
	renaming: boolean;
	onRename: () => void;
	onRenameDone: () => void;
}

// The file name, click-to-rename like a note's. Only the name is editable: the
// extension stays, so a rename never changes what kind of file this is.
export function AttachmentName({ path, editing, onEdit, onDone, className }: NameProps) {
	const { t } = useT();
	const rename = useRenameAttachment();
	const filename = path.split("/").pop() ?? path;
	const { stem, ext } = fileStem(path);
	if (editing) {
		return (
			<span className="flex min-w-0 items-baseline gap-0.5">
				<RenameInput
					initial={stem}
					kind="file"
					// Same as the note title: focus leaving saves, Escape abandons.
					commitOnBlur
					onCommit={(next) => {
						onDone();
						const newPath = attachmentRenamePath(path, next);
						if (newPath) {
							rename.mutate({ old_path: path, new_path: newPath });
						}
					}}
					onCancel={onDone}
				/>
				<span className="text-muted-foreground" translate="no">
					{ext}
				</span>
			</span>
		);
	}
	return (
		<button
			type="button"
			className={cn("min-w-0 rounded text-left hover:bg-accent", className)}
			title={t("Click to rename")}
			onClick={onEdit}
		>
			<span translate="no">{filename}</span>
		</button>
	);
}

// File details under (or, for files with no preview, instead of) the preview:
// what the file is and the actions on it. Notes linking here are in the right
// rail's Backlinks panel, as for a note.
export function AttachmentDetails({
	att,
	kind,
	inlineUrl,
	onDownload,
	renaming,
	onRename,
	onRenameDone,
}: Props) {
	const { t, renderedLocale } = useT();
	const { slug } = useParams();
	const navigate = useNavigate();
	const { data: folders } = useFolders();
	const move = useBatchMoveAttachments();
	const remove = useBatchDeleteAttachments();
	const [mode, setMode] = useState<"move" | "delete" | null>(null);

	const filename = att.path.split("/").pop() ?? att.path;
	const folder = att.path.includes("/") ? att.path.slice(0, att.path.lastIndexOf("/")) : "";
	const Icon = ARCHIVE.test(filename) ? FileArchive : kind ? KIND_ICONS[kind] : File;
	const fmtLocale = intlLocale(renderedLocale);

	return (
		<section aria-label={t("File details")} className="flex shrink-0 flex-col gap-4">
			<header className="flex items-center gap-3">
				<Icon className="size-10 shrink-0 text-muted-foreground" aria-hidden="true" />
				<h2 className="min-w-0 font-semibold text-lg">
					<AttachmentName
						path={att.path}
						editing={renaming}
						onEdit={onRename}
						onDone={onRenameDone}
						className="-mx-1 break-all px-1"
					/>
				</h2>
			</header>

			<dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
				<dt className="text-muted-foreground">{t("Size")}</dt>
				<dd>{formatBytes(att.size_bytes, fmtLocale)}</dd>
				<dt className="text-muted-foreground">{t("Type")}</dt>
				<dd translate="no">{att.mime_type || t("Unknown")}</dd>
				<dt className="text-muted-foreground">{t("Modified")}</dt>
				<dd>{formatDate(att.updated_at, fmtLocale)}</dd>
				<dt className="text-muted-foreground">{t("Folder")}</dt>
				<dd translate="no">{folder || t("Vault root")}</dd>
			</dl>

			<menu className="flex flex-wrap gap-2">
				<li>
					<Button onClick={onDownload}>
						<Download data-icon="inline-start" aria-hidden="true" />
						{t("Download")}
					</Button>
				</li>
				{inlineUrl ? (
					<li>
						<Button variant="outline" asChild>
							<a href={inlineUrl} target="_blank" rel="noopener noreferrer">
								<ExternalLink data-icon="inline-start" aria-hidden="true" />
								{t("Open in new tab")}
							</a>
						</Button>
					</li>
				) : null}
				<li>
					<Button variant="outline" onClick={onRename}>
						<TextCursorInput data-icon="inline-start" aria-hidden="true" />
						{t("Rename")}
					</Button>
				</li>
				<li>
					<Button variant="outline" onClick={() => setMode("move")}>
						<FolderInput data-icon="inline-start" aria-hidden="true" />
						{t("Move to…")}
					</Button>
				</li>
				<li>
					<Button variant="destructive" onClick={() => setMode("delete")}>
						<Trash2 data-icon="inline-start" aria-hidden="true" />
						{t("Delete")}
					</Button>
				</li>
			</menu>

			{mode === "move" ? (
				<MoveDialog
					folders={folders ?? []}
					nodes={[{ kind: "file", path: att.path }]}
					onPick={(target) => {
						setMode(null);
						move.mutate({ paths: [att.path], target_folder: target });
					}}
					onCancel={() => setMode(null)}
				/>
			) : null}
			{mode === "delete" ? (
				<DeleteConfirm
					nodes={[{ kind: "file", path: att.path }]}
					onConfirm={() => {
						setMode(null);
						remove.mutate({ paths: [att.path] });
						navigate(vaultRootHref(slug));
					}}
					onCancel={() => setMode(null)}
				/>
			) : null}
		</section>
	);
}
