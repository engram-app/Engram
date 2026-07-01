import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { PropertyType } from "./property-types";

const TYPES: PropertyType[] = ["text", "list", "number", "checkbox", "date", "datetime"];

export function PropertyTypeMenu({
	value,
	onChange,
}: {
	value: PropertyType;
	onChange: (t: PropertyType) => void;
}) {
	return (
		<DropdownMenu>
			<DropdownMenuTrigger
				aria-label="Property type"
				className="rounded px-1 text-[10px] text-muted-foreground uppercase tracking-wide hover:bg-muted"
			>
				{value}
			</DropdownMenuTrigger>
			<DropdownMenuContent align="start">
				{TYPES.map((t) => (
					<DropdownMenuItem key={t} onSelect={() => onChange(t)}>
						{t}
					</DropdownMenuItem>
				))}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
