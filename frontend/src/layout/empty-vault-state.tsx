import { Link, useLocation } from "react-router";
import { Button } from "@/components/ui/button";
import { settingsTo } from "@/settings/settings-hash";

export function EmptyVaultState() {
	const location = useLocation();
	return (
		<section className="flex flex-col items-center justify-center gap-3 py-16 text-center">
			<h2 className="font-semibold text-foreground text-lg">No vaults</h2>
			<p className="max-w-sm text-muted-foreground text-sm">
				You don't have any vaults right now. Create one to start syncing and searching your notes.
			</p>
			<Button asChild>
				<Link to={settingsTo("vaults", location.search)}>Create a vault</Link>
			</Button>
		</section>
	);
}
