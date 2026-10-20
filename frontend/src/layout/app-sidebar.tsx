import FilesPanel from "./files-panel";
import LazySearchPanel from "./lazy-search-panel";
import Rail from "./rail";
import { useRailView } from "./rail-view-context";

export default function AppSidebarPanel() {
	const { view, sidebarOpen } = useRailView();

	return (
		// Collapsed means clipped to nothing, not unmounted, so inert is what keeps
		// its buttons out of the tab order and the search box from holding focus.
		<div className="flex h-full flex-col" inert={!sidebarOpen}>
			<div className="min-h-0 flex-1">
				{view === "files" ? <FilesPanel /> : <LazySearchPanel />}
			</div>
		</div>
	);
}

export { Rail };
