import {
	Calendar,
	Clock,
	Hash,
	List,
	type LucideIcon,
	SquareCheck,
	Text,
	Trash2,
} from "lucide-react";
import { useRef } from "react";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { MsgKey } from "@/i18n/ui-text";
import type { PropertyType } from "./property-types";

const TYPES: PropertyType[] = ["text", "list", "number", "checkbox", "date", "datetime"];

// Obsidian shows the property's type as the leading icon of the key cell, and
// that icon IS the type picker. The old uppercase text label ate most of the
// key column for something the icon says in 16px.
const TYPE_LABELS: Record<PropertyType, MsgKey> = {
	text: msg("text"),
	list: msg("list"),
	number: msg("number"),
	checkbox: msg("checkbox"),
	date: msg("date"),
	datetime: msg("datetime"),
};

const TYPE_ICONS: Record<PropertyType, LucideIcon> = {
	text: Text,
	list: List,
	number: Hash,
	checkbox: SquareCheck,
	date: Calendar,
	datetime: Clock,
};

export function PropertyTypeMenu({
	value,
	onChange,
	focusAfterSelect,
	onRemove,
	focusAfterRemove,
}: {
	value: PropertyType;
	onChange: (t: PropertyType) => void;
	/** Element to hand focus to once a type is CHOSEN — the property's name, so
	 *  picking a type leaves the caret where the next keystroke belongs. Radix
	 *  restores focus to the trigger on close, so this has to be done in
	 *  `onCloseAutoFocus`; focusing from `onSelect` is overwritten a tick later. */
	focusAfterSelect?: () => HTMLInputElement | null;
	/** Adds a Delete item at the bottom. The menu is the row's only remove
	 *  control, the way Obsidian's property icon menu carries it. */
	onRemove?: () => void;
	/** Element to hand focus to once the property is deleted. The trigger goes
	 *  with its row, so Radix's own restore would land on <body>. */
	focusAfterRemove?: () => HTMLElement | null;
}) {
	const { t } = useT();
	const Icon = TYPE_ICONS[value];
	// Where focus goes on close, set by the item chosen. Escape and click-away
	// leave it null: that is the user backing out, and the trigger is the right
	// place to land.
	const focusTarget = useRef<(() => HTMLElement | null) | null>(null);
	return (
		<DropdownMenu
			onOpenChange={(open) => {
				if (open) {
					focusTarget.current = null;
				}
			}}
		>
			<DropdownMenuTrigger
				// The name carries the CURRENT type, not just the control's purpose.
				// Once the label became an icon the type was conveyed by pixels alone,
				// so a screen reader could open the menu without ever being told what
				// the property already is.
				aria-label={t("Property type: {type}", { type: t(TYPE_LABELS[value]) })}
				// Obsidian's .metadata-property-icon: full row height, and a 4px
				// leading gutter it fakes with a zero-width-space ::before.
				className="ml-1 flex h-7 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
			>
				<Icon aria-hidden="true" className="size-4" />
			</DropdownMenuTrigger>
			<DropdownMenuContent
				align="start"
				onCloseAutoFocus={(e) => {
					const el = focusTarget.current?.();
					if (!el) {
						return;
					}
					e.preventDefault();
					el.focus();
				}}
			>
				{TYPES.map((type) => {
					const ItemIcon = TYPE_ICONS[type];
					return (
						<DropdownMenuItem
							key={type}
							onSelect={() => {
								focusTarget.current = focusAfterSelect ?? null;
								onChange(type);
							}}
						>
							<ItemIcon aria-hidden="true" className="size-4" />
							{t(TYPE_LABELS[type])}
						</DropdownMenuItem>
					);
				})}
				{onRemove ? (
					<>
						<DropdownMenuSeparator />
						<DropdownMenuItem
							variant="destructive"
							onSelect={() => {
								focusTarget.current = focusAfterRemove ?? null;
								onRemove();
							}}
						>
							<Trash2 aria-hidden="true" className="size-4" />
							{t("Delete")}
						</DropdownMenuItem>
					</>
				) : null}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
