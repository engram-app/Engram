import { PanelLeftClose } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useRailView } from "./rail-view-context";

// Sits at the right end of a left-sidebar panel's header: the in-panel way to
// hide the sidebar, mirroring the right panel's collapse button.
export default function CollapseSidebarButton() {
	const { setSidebarOpen } = useRailView();
	return (
		<Button
			variant="ghost"
			size="icon-sm"
			onClick={() => setSidebarOpen(false)}
			aria-label="Collapse sidebar"
			title="Collapse sidebar"
		>
			<PanelLeftClose />
		</Button>
	);
}
