import { createContext, type ReactNode, useCallback, useContext, useEffect, useState } from "react";
import { isMember } from "../lib/is-member";

const STORAGE_KEY = "engram:rail-view";
const OPEN_KEY = "engram:sidebar-open";

interface Ctx {
	view: RailView;
	setView: (v: RailView) => void;
	/** Whether the left sidebar is showing, or collapsed to nothing. */
	sidebarOpen: boolean;
	setSidebarOpen: (open: boolean) => void;
}
const RailViewCtx = createContext<Ctx | null>(null);

const VALID: readonly RailView[] = ["files", "search"];

function readStored(): RailView {
	if (typeof window === "undefined") {
		return "files";
	}
	const raw = window.localStorage.getItem(STORAGE_KEY);
	return isMember(VALID, raw) ? raw : "files";
}

// Anything but an explicit "false" is open: a fresh browser, or a mangled value,
// must never leave the user with no sidebar and no obvious way back.
function readOpen(): boolean {
	if (typeof window === "undefined") {
		return true;
	}
	return window.localStorage.getItem(OPEN_KEY) !== "false";
}

export type RailView = "files" | "search";

export function RailViewProvider({ children }: { children: ReactNode }) {
	const [view, setViewState] = useState<RailView>(readStored);
	const [sidebarOpen, setSidebarOpen] = useState<boolean>(readOpen);

	useEffect(() => {
		window.localStorage.setItem(STORAGE_KEY, view);
	}, [view]);

	useEffect(() => {
		window.localStorage.setItem(OPEN_KEY, String(sidebarOpen));
	}, [sidebarOpen]);

	const setView = useCallback((v: RailView) => setViewState(v), []);
	return (
		<RailViewCtx.Provider value={{ view, setView, sidebarOpen, setSidebarOpen }}>
			{children}
		</RailViewCtx.Provider>
	);
}

export function useRailView(): Ctx {
	const ctx = useContext(RailViewCtx);
	if (!ctx) {
		throw new Error("useRailView must be used inside RailViewProvider");
	}
	return ctx;
}
