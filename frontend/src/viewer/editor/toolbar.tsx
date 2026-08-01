import type { EditorView } from "@codemirror/view";
import { Bold, Code, Heading, Italic, Link, List, Quote } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toggleLinePrefix, toggleWrap } from "./format-commands";

export function EditorToolbar({ getView }: { getView: () => EditorView | null }) {
	const run = (fn: (v: EditorView) => void) => () => {
		const v = getView();
		if (v) {
			fn(v);
		}
	};
	return (
		<div
			className="flex items-center gap-1 border-b px-2 py-1"
			role="toolbar"
			aria-label="Formatting"
		>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Bold"
				onClick={run((v) => toggleWrap(v, "**"))}
			>
				<Bold className="size-4" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Italic"
				onClick={run((v) => toggleWrap(v, "*"))}
			>
				<Italic className="size-4" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Inline code"
				onClick={run((v) => toggleWrap(v, "`"))}
			>
				<Code className="size-4" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Heading"
				onClick={run((v) => toggleLinePrefix(v, "# "))}
			>
				<Heading className="size-4" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Quote"
				onClick={run((v) => toggleLinePrefix(v, "> "))}
			>
				<Quote className="size-4" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="List"
				onClick={run((v) => toggleLinePrefix(v, "- "))}
			>
				<List className="size-4" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Link"
				onClick={run((v) => toggleWrap(v, "[", "](url)"))}
			>
				<Link className="size-4" />
			</Button>
		</div>
	);
}
