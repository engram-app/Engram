import { createContext, useContext } from "react";

/**
 * What the mobile layout lends its pages. `slot` is the top-right corner: a
 * page portals its actions (reading toggle, note menu) there instead of
 * drawing its own header row, the way Obsidian mobile floats them.
 * `openTools` opens the right-hand tools drawer, which has no header button
 * of its own; the note menu carries it. Null outside the mobile layout.
 */
export const MobileHeaderSlot = createContext<{
	slot: HTMLElement | null;
	openTools: () => void;
} | null>(null);

export const useMobileHeaderSlot = () => useContext(MobileHeaderSlot);
