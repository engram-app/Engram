import { Calendar, Clock, Hash, List, type LucideIcon, SquareCheck, Text } from "lucide-react";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { PropertyType } from "./property-types";

const TYPES: PropertyType[] = ["text", "list", "number", "checkbox", "date", "datetime"];

// Obsidian shows the property's type as the leading icon of the key cell, and
// that icon IS the type picker. The old uppercase text label ate most of the
// key column for something the icon says in 16px.
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
}: {
	value: PropertyType;
	onChange: (t: PropertyType) => void;
}) {
	const Icon = TYPE_ICONS[value];
	return (
		<DropdownMenu>
			<DropdownMenuTrigger
				// The name carries the CURRENT type, not just the control's purpose.
				// Once the label became an icon the type was conveyed by pixels alone,
				// so a screen reader could open the menu without ever being told what
				// the property already is.
				aria-label={`Property type: ${value}`}
				// Obsidian's .metadata-property-icon: full row height, and a 4px
				// leading gutter it fakes with a zero-width-space ::before.
				className="ml-1 flex h-7 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
			>
				<Icon aria-hidden="true" className="size-4" />
			</DropdownMenuTrigger>
			<DropdownMenuContent align="start">
				{TYPES.map((t) => {
					const ItemIcon = TYPE_ICONS[t];
					return (
						<DropdownMenuItem key={t} onSelect={() => onChange(t)}>
							<ItemIcon aria-hidden="true" className="size-4" />
							{t}
						</DropdownMenuItem>
					);
				})}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
