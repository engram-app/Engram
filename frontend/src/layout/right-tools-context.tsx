import { BookMarked, ListTree, type LucideIcon } from "lucide-react";
import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useState,
} from "react";

// The right sidebar used to be a single pushed slot: NotePage called
// setContent(<NoteToc/>) on mount and setContent(null) on unmount, and the panel
// collapsed whenever the node was null. Exactly one consumer could exist, which
// is why a second tool (the markdown reference) could not live there.
//
// It is now a small registry. Tools are either:
//   - CONTEXTUAL — they need page state, so a page publishes their node into
//     `slots` and the tool is unavailable (tab hidden) when nothing is there.
//     The outline needs the open note's live content, so it is one of these.
//   - always-on — rendered by the panel itself from a static component, valid
//     on every route. The markdown reference is one of these.

type RightToolId = "outline" | "reference";

interface RightToolDescriptor {
	id: RightToolId;
	label: string;
	Icon: LucideIcon;
	/** True when a page must publish this tool's content for it to be usable. */
	contextual: boolean;
}

const RIGHT_TOOLS: readonly RightToolDescriptor[] = [
	{ id: "outline", label: "Outline", Icon: ListTree, contextual: true },
	{ id: "reference", label: "Reference", Icon: BookMarked, contextual: false },
];

const STORAGE_KEY = "engram:right-tool";

// "" persists an explicitly collapsed panel — distinct from a missing key, which
// means "never chosen" and should fall back to the outline (the old behaviour,
// where opening a note revealed its table of contents).
function readStored(): RightToolId | null {
	if (typeof window === "undefined") {
		return "outline";
	}
	const raw = window.localStorage.getItem(STORAGE_KEY);
	if (raw === "") {
		return null;
	}
	// Missing key or a stale id from an older build both fall back to the outline
	// rather than to a collapsed panel — only an explicit "" means collapsed.
	return RIGHT_TOOLS.some((tool) => tool.id === raw) ? (raw as RightToolId) : "outline";
}

interface RightTools {
	/**
	 * The user's chosen tool. Deliberately RETAINED while that tool is
	 * unavailable, so navigating dashboard → note restores the outline instead of
	 * silently forgetting the preference.
	 */
	activeId: RightToolId | null;
	setActive: (id: RightToolId | null) => void;
	/** Toggle: activating the already-active tool collapses the panel. */
	toggleActive: (id: RightToolId) => void;
	/** The tool that can actually render right now. null ⇒ panel collapses. */
	resolvedId: RightToolId | null;
	isAvailable: (id: RightToolId) => boolean;
	/** Content published by contextual tools. Pages set on mount, clear on unmount. */
	slots: Partial<Record<RightToolId, ReactNode>>;
	setSlot: (id: RightToolId, node: ReactNode) => void;
}

const Ctx = createContext<RightTools | null>(null);

function RightToolsProvider({ children }: { children: ReactNode }) {
	const [activeId, setActiveState] = useState<RightToolId | null>(readStored);
	const [slots, setSlots] = useState<Partial<Record<RightToolId, ReactNode>>>({});

	useEffect(() => {
		window.localStorage.setItem(STORAGE_KEY, activeId ?? "");
	}, [activeId]);

	const setActive = useCallback((id: RightToolId | null) => setActiveState(id), []);
	const toggleActive = useCallback(
		(id: RightToolId) => setActiveState((prev) => (prev === id ? null : id)),
		[],
	);

	const setSlot = useCallback((id: RightToolId, node: ReactNode) => {
		setSlots((prev) => {
			// Referential no-op guard: NotePage re-publishes the outline on every
			// content keystroke, and an unconditional setState here would loop.
			if (prev[id] === node) {
				return prev;
			}
			return { ...prev, [id]: node };
		});
	}, []);

	const value = useMemo<RightTools>(() => {
		const isAvailable = (id: RightToolId) => {
			const tool = RIGHT_TOOLS.find((t) => t.id === id);
			if (!tool) {
				return false;
			}
			return tool.contextual ? slots[id] !== null && slots[id] !== undefined : true;
		};
		return {
			activeId,
			setActive,
			toggleActive,
			resolvedId: activeId !== null && isAvailable(activeId) ? activeId : null,
			isAvailable,
			slots,
			setSlot,
		};
	}, [activeId, slots, setActive, toggleActive, setSlot]);

	return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

function useRightTools(): RightTools {
	const ctx = useContext(Ctx);
	if (!ctx) {
		throw new Error("useRightTools must be used inside RightToolsProvider");
	}
	return ctx;
}

export type { RightToolDescriptor, RightToolId };
export { RIGHT_TOOLS, RightToolsProvider, useRightTools };
