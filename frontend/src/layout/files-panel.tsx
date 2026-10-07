import { useT } from "@/i18n/locale-provider";
import FolderTree from "../viewer/folder-tree";
import CollapseSidebarButton from "./collapse-sidebar-button";
import FolderActions from "./folder-actions";
import { FolderTreeProvider } from "./folder-tree-context";
import VaultSwitcher from "./vault-switcher";

export default function FilesPanel() {
	const { t } = useT();
	return (
		<FolderTreeProvider>
			<div className="flex h-full flex-col">
				<header className="flex shrink-0 items-center justify-between border-border border-b py-1 pr-1 pl-3">
					<h2 className="font-semibold text-muted-foreground text-xs uppercase tracking-wide">
						{t("Files")}
					</h2>
					<CollapseSidebarButton />
				</header>
				<FolderTree />
				<FolderActions />
				<VaultSwitcher />
			</div>
		</FolderTreeProvider>
	);
}
