import { Search } from "lucide-react";
import type { ComponentProps } from "react";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

// The one search box: the Files/Search sidebar and the vault picker both render
// this, so the shape, icon and focus ring change in one place. `className`
// applies to the wrapping label (e.g. `flex-1`); everything else goes to the input.
export function SearchField({ className, ...props }: ComponentProps<"input">) {
	return (
		<label className={cn("relative block", className)}>
			<Search className="pointer-events-none absolute top-1/2 left-2 size-3.5 -translate-y-1/2 text-muted-foreground" />
			<Input type="search" className="pl-7" {...props} />
		</label>
	);
}
