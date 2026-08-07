import FolderTree from "../viewer/folder-tree";
import FolderActions from "./folder-actions";
import { FolderTreeProvider } from "./folder-tree-context";
import VaultSwitcher from "./vault-switcher";

export default function FilesPanel() {
	return (
		<FolderTreeProvider>
			<div className="flex h-full flex-col">
				<header className="flex shrink-0 items-center border-border border-b px-3 py-2">
					<h2 className="font-semibold text-muted-foreground text-xs uppercase tracking-wide">
						Files
					</h2>
				</header>
				<FolderTree />
				<FolderActions />
				<VaultSwitcher />
			</div>
		</FolderTreeProvider>
	);
}
