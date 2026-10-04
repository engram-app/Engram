import type { ReactNode } from "react";
import { ScrollArea } from "@/components/ui/scroll-area";

// Scrolling body for an attachment preview (image, PDF). It sits inside the
// DocumentSurface under the DocumentHeader, so it only supplies the scroll area;
// callers render their own content, centered with a shadow.
export default function PreviewColumn({ children }: { children: ReactNode }) {
	return <ScrollArea className="min-h-0 flex-1">{children}</ScrollArea>;
}
