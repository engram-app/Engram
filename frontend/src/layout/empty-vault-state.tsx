import { Link, useLocation } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { settingsTo } from "@/settings/settings-hash";

export function EmptyVaultState() {
	const location = useLocation();
	const { t } = useT();
	return (
		<section className="flex flex-col items-center justify-center gap-3 py-16 text-center">
			<h2 className="font-semibold text-foreground text-lg">{t("No vaults")}</h2>
			<p className="max-w-sm text-muted-foreground text-sm">
				{t(
					"You don't have any vaults right now. Create one to start syncing and searching your notes.",
				)}
			</p>
			<Button asChild>
				<Link to={settingsTo("vaults", location.search)}>{t("Create a vault")}</Link>
			</Button>
		</section>
	);
}
