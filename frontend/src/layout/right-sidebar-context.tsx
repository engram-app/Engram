import { createContext, type ReactNode, useContext, useMemo, useState } from "react";

interface RightSidebar {
	/** Slot content. Pages call setContent(node) on mount, setContent(null) on unmount. */
	content: ReactNode;
	setContent: (next: ReactNode) => void;
	collapsed: boolean;
	setCollapsed: (next: boolean) => void;
}

const Ctx = createContext<RightSidebar | null>(null);

export function RightSidebarProvider({ children }: { children: ReactNode }) {
	const [content, setContent] = useState<ReactNode>(null);
	const [collapsed, setCollapsed] = useState(false);

	const value = useMemo(
		() => ({ content, setContent, collapsed, setCollapsed }),
		[content, collapsed],
	);

	return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useRightSidebar() {
	const ctx = useContext(Ctx);
	if (!ctx) {
		throw new Error("useRightSidebar must be used within RightSidebarProvider");
	}
	return ctx;
}
