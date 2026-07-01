import { ActiveVaultsSection } from "./vaults/active-vaults-section";
import { DeletedVaultsSection } from "./vaults/deleted-vaults-section";

export default function VaultsPage() {
	return (
		<article className="space-y-6">
			<header>
				<h1 className="text-xl font-semibold text-foreground">Vaults</h1>
				<p className="mt-1 text-sm text-muted-foreground">
					Manage, create, and recover your vaults.
				</p>
			</header>

			<ActiveVaultsSection />
			<DeletedVaultsSection />
		</article>
	);
}
