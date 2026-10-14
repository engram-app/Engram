import { createContext, useContext } from "react";

// The mobile layout's top-right corner. A page portals its actions (reading
// toggle, note menu) here instead of drawing its own header row, the way
// Obsidian mobile floats them. Null outside the mobile layout.
export const MobileHeaderSlot = createContext<HTMLElement | null>(null);

export const useMobileHeaderSlot = () => useContext(MobileHeaderSlot);
