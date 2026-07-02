import { createContext, type ReactNode, useCallback, useContext, useEffect, useState } from "react";

const STORAGE_KEY = "engram:rail-view";

interface Ctx {
	view: RailView;
	setView: (v: RailView) => void;
}
const RailViewCtx = createContext<Ctx | null>(null);

const VALID: ReadonlySet<RailView> = new Set(["files", "search"]);

function readStored(): RailView {
	if (typeof window === "undefined") {
		return "files";
	}
	const raw = window.localStorage.getItem(STORAGE_KEY);
	return raw && VALID.has(raw as RailView) ? (raw as RailView) : "files";
}

export type RailView = "files" | "search";

export function RailViewProvider({ children }: { children: ReactNode }) {
	const [view, setViewState] = useState<RailView>(readStored);

	useEffect(() => {
		window.localStorage.setItem(STORAGE_KEY, view);
	}, [view]);

	const setView = useCallback((v: RailView) => setViewState(v), []);
	return <RailViewCtx.Provider value={{ view, setView }}>{children}</RailViewCtx.Provider>;
}

export function useRailView(): Ctx {
	const ctx = useContext(RailViewCtx);
	if (!ctx) {
		throw new Error("useRailView must be used inside RailViewProvider");
	}
	return ctx;
}
