import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useMemo,
	useRef,
	useState,
} from "react";

interface FolderTreeContextValue {
	collapseAll: () => void;
	/**
	 * The tree registers the real collapse here on mount. Expansion state lives
	 * in the headless tree, not in this provider — an open-set kept here would
	 * be read by nobody, which is exactly how the toolbar button ended up
	 * clearing state that no longer drove the UI.
	 */
	registerCollapseAll: (fn: (() => void) | null) => void;
	sort: SortKey;
	setSort: (next: SortKey) => void;
	// Path of a just-created folder that should open in rename mode. Lives here
	// rather than in FolderTree because the creating component (the toolbar) and
	// the component that owns rename state (the tree) are siblings.
	pendingFolderRename: string | null;
	requestFolderRename: (path: string) => void;
	clearFolderRename: () => void;
}

const FolderTreeContext = createContext<FolderTreeContextValue | null>(null);

export type SortKey =
	| "name-asc"
	| "name-desc"
	| "created-desc"
	| "created-asc"
	| "modified-desc"
	| "modified-asc";

export function FolderTreeProvider({ children }: { children: ReactNode }) {
	const [sort, setSort] = useState<SortKey>("name-asc");
	const [pendingFolderRename, setPendingFolderRename] = useState<string | null>(null);

	// A ref, not state: re-rendering every consumer because the tree mounted
	// would buy nothing, and collapseAll's identity must stay stable so passing
	// it to the toolbar doesn't churn.
	const collapseHandlerRef = useRef<(() => void) | null>(null);
	const registerCollapseAll = useCallback((fn: (() => void) | null) => {
		collapseHandlerRef.current = fn;
	}, []);
	const collapseAll = useCallback(() => collapseHandlerRef.current?.(), []);
	const requestFolderRename = useCallback((path: string) => setPendingFolderRename(path), []);
	const clearFolderRename = useCallback(() => setPendingFolderRename(null), []);

	const value = useMemo(
		() => ({
			collapseAll,
			registerCollapseAll,
			sort,
			setSort,
			pendingFolderRename,
			requestFolderRename,
			clearFolderRename,
		}),
		[
			collapseAll,
			registerCollapseAll,
			sort,
			pendingFolderRename,
			requestFolderRename,
			clearFolderRename,
		],
	);
	return <FolderTreeContext.Provider value={value}>{children}</FolderTreeContext.Provider>;
}

export function useFolderTreeState(): FolderTreeContextValue {
	const v = useContext(FolderTreeContext);
	if (!v) {
		throw new Error("useFolderTreeState must be used inside FolderTreeProvider");
	}
	return v;
}
