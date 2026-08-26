import { ArrowUpDown, FilePlus, FolderPlus, FoldVertical, Upload } from "lucide-react";
import { Fragment } from "react";
import { useCreateFolder, useCreateNote } from "@/api/queries";
import { Button } from "@/components/ui/button";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuLabel,
	DropdownMenuRadioGroup,
	DropdownMenuRadioItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { uuid7 } from "@/crdt/uuid7";
import { useAttachmentUpload } from "../viewer/attachment-upload/provider";
import { type SortKey, useFolderTreeState } from "./folder-tree-context";
import { isMember } from "../lib/is-member";

const ICON = "size-5";
const BUTTON = "size-10";

interface SortSection {
	label: string;
	options: ReadonlyArray<{ value: SortKey; label: string }>;
}

const SORT_SECTIONS: readonly SortSection[] = [
	{
		label: "File name",
		options: [
			{ value: "name-asc", label: "A to Z" },
			{ value: "name-desc", label: "Z to A" },
		],
	},
	{
		label: "Created time",
		options: [
			{ value: "created-desc", label: "Newest first" },
			{ value: "created-asc", label: "Oldest first" },
		],
	},
	{
		label: "Modified time",
		options: [
			{ value: "modified-desc", label: "Newest first" },
			{ value: "modified-asc", label: "Oldest first" },
		],
	},
];

// Radix hands onValueChange a bare string; check it against the same list the
// items are rendered from rather than asserting the cast.
const SORT_KEYS: readonly SortKey[] = SORT_SECTIONS.flatMap((s) => s.options.map((o) => o.value));

export default function FolderActions() {
	const { collapseAll, sort, setSort, requestFolderRename } = useFolderTreeState();

	const createNote = useCreateNote();
	const createFolder = useCreateFolder();
	const { openUpload } = useAttachmentUpload();

	return (
		<section
			aria-label="File actions"
			// No horizontal padding: justify-around already yields edge gaps that
			// scale with the panel, so the spacing breathes as the sidebar widens
			// and collapses to flush at the 200px floor instead of clipping.
			className="flex items-center justify-around border-border border-t bg-card py-0.5"
		>
			<TooltipProvider delayDuration={300}>
				<Tooltip>
					<TooltipTrigger asChild>
						<Button
							variant="ghost"
							size="icon"
							aria-label="New note"
							className={BUTTON}
							onClick={() => createNote.mutate({ folder: "", id: uuid7() })}
							disabled={createNote.isPending}
						>
							<FilePlus className={ICON} />
						</Button>
					</TooltipTrigger>
					<TooltipContent>Create note</TooltipContent>
				</Tooltip>

				<Tooltip>
					<TooltipTrigger asChild>
						<Button
							variant="ghost"
							size="icon"
							aria-label="New folder"
							className={BUTTON}
							// Straight into rename mode so the placeholder name is never kept by
							// accident — the tree owns the rename UI, so ask it via context.
							onClick={() =>
								createFolder.mutate(
									{ parent: "" },
									{ onSuccess: ({ folder }) => requestFolderRename(folder) },
								)
							}
							disabled={createFolder.isPending}
						>
							<FolderPlus className={ICON} />
						</Button>
					</TooltipTrigger>
					<TooltipContent>Create folder</TooltipContent>
				</Tooltip>

				<Tooltip>
					<TooltipTrigger asChild>
						<Button
							variant="ghost"
							size="icon"
							aria-label="Upload attachment"
							className={BUTTON}
							onClick={() => openUpload(undefined, "")}
						>
							<Upload className={ICON} />
						</Button>
					</TooltipTrigger>
					<TooltipContent>Upload an attachment</TooltipContent>
				</Tooltip>
				<DropdownMenu>
					<Tooltip>
						<TooltipTrigger asChild>
							{/* Both triggers compose onto the one Button via asChild. */}
							<DropdownMenuTrigger asChild>
								<Button variant="ghost" size="icon" aria-label="Sort" className={BUTTON}>
									<ArrowUpDown className={ICON} />
								</Button>
							</DropdownMenuTrigger>
						</TooltipTrigger>
						<TooltipContent>Sort</TooltipContent>
					</Tooltip>
					<DropdownMenuContent align="end" className="w-[min(95vw,20rem)]">
						<DropdownMenuRadioGroup
							value={sort}
							onValueChange={(v) => {
								if (isMember(SORT_KEYS, v)) {
									setSort(v);
								}
							}}
						>
							{SORT_SECTIONS.map((section, i) => (
								// Fragment (not <section>) so Radix's roving keyboard nav across
								// DropdownMenuRadioItem siblings keeps working — wrapping them in
								// a real DOM element breaks the radio group.
								<Fragment key={section.label}>
									{i > 0 && <DropdownMenuSeparator />}
									<DropdownMenuLabel className="text-[10px] text-muted-foreground uppercase tracking-wide">
										{section.label}
									</DropdownMenuLabel>
									{section.options.map((opt) => (
										<DropdownMenuRadioItem key={opt.value} value={opt.value}>
											{opt.label}
										</DropdownMenuRadioItem>
									))}
								</Fragment>
							))}
						</DropdownMenuRadioGroup>
					</DropdownMenuContent>
				</DropdownMenu>

				<Tooltip>
					<TooltipTrigger asChild>
						<Button
							variant="ghost"
							size="icon"
							aria-label="Collapse all folders"
							onClick={collapseAll}
							className={BUTTON}
						>
							<FoldVertical className={ICON} />
						</Button>
					</TooltipTrigger>
					<TooltipContent>Collapse all folders</TooltipContent>
				</Tooltip>
			</TooltipProvider>
		</section>
	);
}
