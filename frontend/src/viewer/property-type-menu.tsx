import { Calendar, Clock, Hash, List, type LucideIcon, SquareCheck, Text } from "lucide-react";
import { useRef } from "react";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { PropertyType } from "./property-types";

const TYPES: PropertyType[] = ["text", "list", "number", "checkbox", "date", "datetime"];

// Obsidian shows the property's type as the leading icon of the key cell, and
// that icon IS the type picker. The old uppercase text label ate most of the
// key column for something the icon says in 16px.
const TYPE_LABELS: Record<PropertyType, string> = {
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
}: {
	value: PropertyType;
	onChange: (t: PropertyType) => void;
	/** Element to hand focus to once a type is CHOSEN — the property's name, so
	 *  picking a type leaves the caret where the next keystroke belongs. Radix
	 *  restores focus to the trigger on close, so this has to be done in
	 *  `onCloseAutoFocus`; focusing from `onSelect` is overwritten a tick later. */
	focusAfterSelect?: () => HTMLInputElement | null;
}) {
	const { t } = useT();
	const Icon = TYPE_ICONS[value];
	// Only a SELECTION redirects focus. Escape and click-away are the user
	// backing out, and there the trigger is the right place to land.
	const picked = useRef(false);
	return (
		<DropdownMenu
			onOpenChange={(open) => {
				if (open) {
					picked.current = false;
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
					if (!picked.current) {
						return;
					}
					const el = focusAfterSelect?.();
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
								picked.current = true;
								onChange(type);
							}}
						>
							<ItemIcon aria-hidden="true" className="size-4" />
							{t(TYPE_LABELS[type])}
						</DropdownMenuItem>
					);
				})}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
