import { Link, useLocation } from "react-router";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import { settingsTo } from "../settings/settings-hash";
import FilesPanel from "./files-panel";
import Rail from "./rail";
import { useRailView } from "./rail-view-context";
import SearchPanel from "./search-panel";

export default function AppSidebarPanel() {
	const { view } = useRailView();
	const showFreeFooter = useIsFreeTier();
	const location = useLocation();

	return (
		<div className="flex h-full flex-col">
			<div className="min-h-0 flex-1">{view === "files" ? <FilesPanel /> : <SearchPanel />}</div>
			{showFreeFooter && (
				<div className="border-border border-t px-3 py-2 text-muted-foreground text-xs">
					Free tier: 1 connection.{" "}
					<Link
						to={settingsTo("billing", location.search)}
						className="font-medium text-foreground underline underline-offset-4"
					>
						Upgrade
					</Link>
				</div>
			)}
		</div>
	);
}

export { Rail };
