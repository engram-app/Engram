import { Link } from "react-router";
import { Button } from "@/components/ui/button";

export function EmptyVaultState() {
	return (
		<section className="flex flex-col items-center justify-center gap-3 py-16 text-center">
			<h2 className="font-semibold text-foreground text-lg">No vaults</h2>
			<p className="max-w-sm text-muted-foreground text-sm">
				You don't have any vaults right now. Create one to start syncing and searching your notes.
			</p>
			<Button asChild>
				<Link to="/settings/vaults">Create a vault</Link>
			</Button>
		</section>
	);
}
