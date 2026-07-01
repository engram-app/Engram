import { ActiveVaultsSection } from "./vaults/active-vaults-section";
import { DeletedVaultsSection } from "./vaults/deleted-vaults-section";

export default function VaultsPage() {
	return (
		<article className="space-y-6">
			<header>
				<h1 className="font-semibold text-foreground text-xl">Vaults</h1>
				<p className="mt-1 text-muted-foreground text-sm">
					Manage, create, and recover your vaults.
				</p>
			</header>

			<ActiveVaultsSection />
			<DeletedVaultsSection />
		</article>
	);
}
