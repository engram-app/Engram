import { type ReactNode, useState } from "react";
import { useAttachments, useBatchMoveAttachments, useRenameAttachment } from "@/api/queries";
import { baseOf, dirOf, joinPath } from "@/api/vault-tree-patch";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { uniqueAttachmentName } from "../attachment-blob";
import { fileStem } from "../attachment-preview";

const lower = (s: string) => s.toLowerCase();

// Names already in `folder`, lowercased. The server only refuses an exact-path
// clash, but a case-only twin ("Photo.png" next to "photo.png") is one file on
// a macOS or Windows Obsidian disk, so the client treats it as taken too.
function namesIn(folder: string, attachments: readonly { path: string }[]): Set<string> {
	return new Set(
		attachments.filter((a) => dirOf(a.path) === folder).map((a) => lower(baseOf(a.path))),
	);
}

interface Pending {
	paths: string[];
	target: string;
	clashes: string[];
}

function RenameToMove({
	path,
	target,
	taken,
	onMove,
	onCancel,
}: {
	path: string;
	target: string;
	taken: Set<string>;
	onMove: (name: string) => void;
	onCancel: () => void;
}) {
	const { t } = useT();
	const name = baseOf(path);
	const { ext } = fileStem(path);
	const [stem, setStem] = useState(
		() =>
			fileStem(
				uniqueAttachmentName(
					[...taken].map((n) => ({ path: n })),
					name,
				),
			).stem,
	);
	const next = `${stem.trim()}${ext}`;
	const clash = taken.has(lower(next));
	const invalid = !stem.trim() || stem.includes("/");
	const folder = target || t("Vault root");

	return (
		<Dialog open onOpenChange={(open) => !open && onCancel()}>
			<DialogContent showCloseButton={false}>
				<DialogTitle className="text-sm">
					{t("{folder} already has a file named {name}", { folder, name })}
				</DialogTitle>
				<DialogDescription className="text-xs">
					{t("Give the file you're moving a new name.")}
				</DialogDescription>
				<form
					className="flex flex-col gap-1"
					onSubmit={(e) => {
						e.preventDefault();
						if (!(clash || invalid)) {
							onMove(next);
						}
					}}
				>
					<span className="flex items-baseline gap-1">
						<Input
							autoFocus
							aria-label={t("New name")}
							value={stem}
							onChange={(e) => setStem(e.target.value)}
						/>
						<span className="text-muted-foreground text-sm" translate="no">
							{ext}
						</span>
					</span>
					{clash ? (
						<p className="text-destructive text-xs">{t("That name is taken too.")}</p>
					) : null}
					<DialogFooter className="mt-2">
						<Button type="button" variant="outline" onClick={onCancel}>
							{t("Cancel")}
						</Button>
						<Button type="submit" disabled={clash || invalid}>
							{t("Move")}
						</Button>
					</DialogFooter>
				</form>
			</DialogContent>
		</Dialog>
	);
}

function KeepBoth({
	pending,
	inFolder,
	onKeepBoth,
	onCancel,
}: {
	pending: Pending;
	/** Names already in the target folder, lowercased. */
	inFolder: Set<string>;
	onKeepBoth: () => void;
	onCancel: () => void;
}) {
	const { t, tn } = useT();
	const folder = pending.target || t("Vault root");
	// A clash can also be between two files in this move, which the folder
	// does not hold at all.
	const allInFolder = pending.clashes.every((path) => inFolder.has(lower(baseOf(path))));
	return (
		<Dialog open onOpenChange={(open) => !open && onCancel()}>
			<DialogContent showCloseButton={false}>
				<DialogTitle className="text-sm">
					{allInFolder
						? tn(
								{
									one: "{folder} already has a file with this name",
									other: "{folder} already has files with these {count} names",
								},
								pending.clashes.length,
								{ folder },
							)
						: tn(
								{
									one: "This file would share a name with another in {folder}",
									other: "These {count} files would share a name with others in {folder}",
								},
								pending.clashes.length,
								{ folder },
							)}
				</DialogTitle>
				<DialogDescription className="text-xs">
					{t("Keep both to move them with a number added to the name.")}
				</DialogDescription>
				<ul className="max-h-40 overflow-auto text-sm" translate="no">
					{pending.clashes.map((path) => (
						<li key={path}>{baseOf(path)}</li>
					))}
				</ul>
				<DialogFooter>
					<Button variant="outline" onClick={onCancel}>
						{t("Cancel")}
					</Button>
					<Button onClick={onKeepBoth}>{t("Keep both")}</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}

/**
 * The files in `paths` whose name is already taken in `target`: by a file
 * there now, or by an earlier file in this same move. A file already in
 * `target` moves nowhere, so it never clashes.
 */
export function findMoveClashes(
	paths: readonly string[],
	target: string,
	attachments: readonly { path: string }[],
): string[] {
	const taken = namesIn(target, attachments);
	const clashes: string[] = [];
	for (const path of paths) {
		if (dirOf(path) === target) {
			continue;
		}
		const name = lower(baseOf(path));
		if (taken.has(name)) {
			clashes.push(path);
		}
		taken.add(name);
	}
	return clashes;
}

/**
 * Move attachments into a folder, asking first when a name is taken there.
 * The server refuses such a move outright, so this catches it before the
 * request: one clashing file gets a rename box, several get "Keep both". The
 * caller renders `dialog`.
 */
export function useAttachmentMove(): {
	move: (paths: string[], target: string) => void;
	dialog: ReactNode;
} {
	const { data: attachments = [] } = useAttachments();
	const batchMove = useBatchMoveAttachments();
	const rename = useRenameAttachment();
	const [pending, setPending] = useState<Pending | null>(null);

	function move(paths: string[], target: string) {
		const clashes = findMoveClashes(paths, target, attachments);
		if (clashes.length === 0) {
			batchMove.mutate({ paths, target_folder: target });
			return;
		}
		setPending({ paths, target, clashes });
	}

	const clearOf = (p: Pending) => p.paths.filter((path) => !p.clashes.includes(path));

	// Moves the files that do not clash, THEN each clashing one under `nameFor`.
	// In that order: a rename sent alongside the batch could race it for one
	// name, and the batch is all-or-nothing, so losing the race moved nothing.
	// A refused batch is already toasted by its hook, so the renames are dropped.
	async function finish(p: Pending, nameFor: (path: string) => string) {
		setPending(null);
		const clear = clearOf(p);
		if (clear.length > 0) {
			try {
				await batchMove.mutateAsync({ paths: clear, target_folder: p.target });
			} catch {
				return;
			}
		}
		for (const path of p.clashes) {
			rename.mutate({ old_path: path, new_path: joinPath(p.target, nameFor(path)) });
		}
	}

	function keepBoth(p: Pending) {
		// Taken = what is in the target now plus what this move brings in.
		const taken = [
			...namesIn(p.target, attachments),
			...clearOf(p).map((path) => lower(baseOf(path))),
		].map((name) => ({ path: name }));
		finish(p, (path) => {
			const name = uniqueAttachmentName(taken, baseOf(path));
			taken.push({ path: lower(name) });
			return name;
		});
	}

	const dialog =
		pending === null ? null : pending.clashes.length === 1 && pending.paths.length === 1 ? (
			<RenameToMove
				path={pending.clashes[0] ?? ""}
				target={pending.target}
				taken={namesIn(pending.target, attachments)}
				onMove={(name) => finish(pending, () => name)}
				onCancel={() => setPending(null)}
			/>
		) : (
			<KeepBoth
				pending={pending}
				inFolder={namesIn(pending.target, attachments)}
				onKeepBoth={() => keepBoth(pending)}
				onCancel={() => setPending(null)}
			/>
		);

	return { move, dialog };
}
