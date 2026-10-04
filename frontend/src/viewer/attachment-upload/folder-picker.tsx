import { useId, useState } from "react";
import { SearchField } from "@/components/search-field";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
	LIST_ROW_GAP,
	LIST_ROW_HEIGHT,
	listContainer,
	listEmpty,
	listRowClass,
} from "@/lib/ui-classes";
import { cn } from "@/lib/utils";

interface Props {
	/** Folder paths; the vault root ("") is added here unless `includeRoot` is false. */
	folders: string[];
	includeRoot?: boolean;
	value: string;
	/** The selection moved (arrows, a click, or the search narrowing past it). */
	onChange: (folder: string) => void;
	/** The user chose a folder: a click on its row, or Enter in the search box. */
	onActivate?: (folder: string) => void;
	placeholder?: string;
	className?: string;
}

const label = (name: string): string => (name === "" ? "/ (root)" : name);

// Search box + scrollable list of folders, same row look as the file tree.
// Arrow keys on the search box or the list move the selection.
export function FolderPicker({
	folders,
	includeRoot = true,
	value,
	onChange,
	onActivate,
	placeholder = "Search folders…",
	className,
}: Props) {
	const id = useId();
	const optionId = (i: number): string => `${id}-opt-${i}`;
	const [query, setQuery] = useState("");
	const matchesFor = (text: string) => {
		const q = text.trim().toLowerCase();
		return (includeRoot ? ["", ...folders] : folders).filter((name) =>
			label(name).toLowerCase().includes(q),
		);
	};
	const matches = matchesFor(query);
	const activeIndex = matches.indexOf(value);

	function onKeyDown(e: React.KeyboardEvent) {
		const last = matches.length - 1;
		let next: number;
		if (e.key === "ArrowDown") {
			next = Math.min(activeIndex + 1, last);
		} else if (e.key === "ArrowUp") {
			next = Math.max(activeIndex - 1, 0);
		} else if (e.key === "Home" && e.currentTarget.getAttribute("role") === "listbox") {
			next = 0;
		} else if (e.key === "End" && e.currentTarget.getAttribute("role") === "listbox") {
			next = last;
		} else {
			return;
		}
		e.preventDefault();
		onChange(matches[next] ?? value);
	}

	return (
		<div className={cn("flex min-h-0 flex-col", className)}>
			<SearchField
				role="combobox"
				aria-label="Search folders"
				aria-expanded
				aria-controls={`${id}-list`}
				aria-activedescendant={activeIndex >= 0 ? optionId(activeIndex) : undefined}
				placeholder={placeholder}
				autoFocus
				autoComplete="off"
				spellCheck={false}
				value={query}
				onChange={(e) => {
					setQuery(e.target.value);
					// Keep the selection on something that is still listed.
					const [first] = matchesFor(e.target.value);
					if (first !== undefined && !matchesFor(e.target.value).includes(value)) {
						onChange(first);
					}
				}}
				onKeyDown={(e) => {
					if (e.key === "Enter" && onActivate && matches[activeIndex] !== undefined) {
						e.preventDefault();
						onActivate(matches[activeIndex]);
						return;
					}
					onKeyDown(e);
				}}
				className="mb-2"
			/>
			<ScrollArea
				className="min-h-0 flex-1 rounded-md border border-border bg-background"
				viewportClassName="max-h-full"
			>
				<div
					id={`${id}-list`}
					role="listbox"
					aria-label="Destination folder"
					tabIndex={0}
					onKeyDown={onKeyDown}
					aria-activedescendant={activeIndex >= 0 ? optionId(activeIndex) : undefined}
					className={cn("flex flex-col outline-none", listContainer)}
					style={{ gap: LIST_ROW_GAP }}
				>
					{matches.map((name, i) => (
						// biome-ignore lint/a11y/useFocusableInteractive lint/a11y/useKeyWithClickEvents: option in an aria-activedescendant listbox; options are intentionally not individually focusable and keyboard handling is on the listbox above
						<div
							key={name || "__root__"}
							id={optionId(i)}
							role="option"
							aria-selected={name === value}
							onClick={() => {
								onChange(name);
								onActivate?.(name);
							}}
							style={{ height: LIST_ROW_HEIGHT }}
							className={cn(
								listRowClass({ selected: name === value }),
								"cursor-pointer pl-2 outline-none",
							)}
						>
							<span className="truncate">{label(name)}</span>
						</div>
					))}
					{matches.length === 0 ? <p className={listEmpty}>No folders match</p> : null}
				</div>
			</ScrollArea>
		</div>
	);
}
