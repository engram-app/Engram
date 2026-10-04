import { Link, useLocation } from "react-router";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import { settingsTo } from "../settings/settings-hash";
import FilesPanel from "./files-panel";
import Rail from "./rail";
import { useRailView } from "./rail-view-context";
import SearchPanel from "./search-panel";

export default function AppSidebarPanel() {
	const { t } = useT();
	const { view, sidebarOpen } = useRailView();
	const showFreeFooter = useIsFreeTier();
	const location = useLocation();

	return (
		// Collapsed means clipped to nothing, not unmounted, so inert is what keeps
		// its buttons out of the tab order and the search box from holding focus.
		<div className="flex h-full flex-col" inert={!sidebarOpen}>
			<div className="min-h-0 flex-1">{view === "files" ? <FilesPanel /> : <SearchPanel />}</div>
			{showFreeFooter && (
				<div className="border-border border-t px-3 py-2 text-muted-foreground text-xs">
					<Trans
						text="Free tier: 1 connection. {upgrade}"
						slots={{
							upgrade: (
								<Link
									to={settingsTo("billing", location.search)}
									className="font-medium text-foreground underline underline-offset-4"
								>
									{t("Upgrade")}
								</Link>
							),
						}}
					/>
				</div>
			)}
		</div>
	);
}

export { Rail };
