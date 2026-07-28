import { PanelRightClose } from "lucide-react";
import { lazy, type ReactNode, Suspense } from "react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { RIGHT_TOOLS, type RightToolId, useRightTools } from "./right-tools-context";

// Lazy on purpose. The reference panel reaches insertSnippet, which pulls in
// @codemirror/{state,view} — today those live only in the note-page chunk.
// Importing it eagerly here would drag CodeMirror into the always-loaded app
// shell, the exact regression the router's code-splitting comments guard.
const MarkdownReferencePanel = lazy(() => import("../viewer/reference/markdown-reference-panel"));

// Tools that render themselves from static data, valid on every route. Anything
// not listed here is contextual and reads its node out of `slots`.
const STATIC_TOOLS: Partial<Record<RightToolId, () => ReactNode>> = {
	reference: () => <MarkdownReferencePanel />,
};

export default function RightToolPanel({ onCollapse }: { onCollapse: () => void }) {
	const { resolvedId, setActive, isAvailable, slots } = useRightTools();
	const available = RIGHT_TOOLS.filter((tool) => isAvailable(tool.id));

	const renderStatic = resolvedId ? STATIC_TOOLS[resolvedId] : undefined;

	return (
		<section className="flex h-full min-h-0 flex-col">
			<header className="flex shrink-0 items-center gap-1 border-border border-b px-1 py-1">
				{/* Plain container, not <nav>: role="tablist" is a widget role, and
				    layering it over landmark semantics is what a11y linters flag. */}
				<div role="tablist" aria-label="Sidebar tools" className="flex min-w-0 flex-1 gap-1">
					{available.map((tool) => (
						<button
							key={tool.id}
							type="button"
							role="tab"
							id={`right-tool-tab-${tool.id}`}
							aria-selected={resolvedId === tool.id}
							aria-controls="right-tool-panel"
							onClick={() => setActive(tool.id)}
							className={`rounded px-2 py-1 font-medium text-xs transition-colors ${
								resolvedId === tool.id
									? "bg-primary/15 text-primary"
									: "text-muted-foreground hover:bg-primary/10 hover:text-primary"
							}`}
						>
							{tool.label}
						</button>
					))}
				</div>
				<Button
					variant="ghost"
					size="icon-sm"
					onClick={onCollapse}
					aria-label="Collapse panel"
					title="Collapse panel"
				>
					<PanelRightClose />
				</Button>
			</header>

			{/* overflow-hidden is load-bearing: without it this flex item can grow past
			    the panel when a tool's content is tall, and the ancestor picks up a
			    native scrollbar alongside the tool's own ScrollArea. */}
			<section
				id="right-tool-panel"
				role="tabpanel"
				aria-labelledby={resolvedId ? `right-tool-tab-${resolvedId}` : undefined}
				className="min-h-0 flex-1 overflow-hidden"
			>
				{renderStatic ? (
					<Suspense fallback={<p className="p-3 text-muted-foreground text-sm">Loading…</p>}>
						{renderStatic()}
					</Suspense>
				) : (
					// Contextual tools publish plain content and rely on the panel for
					// scrolling; static ones manage their own (search box stays pinned).
					<ScrollArea className="h-full">{resolvedId ? slots[resolvedId] : null}</ScrollArea>
				)}
			</section>
		</section>
	);
}
