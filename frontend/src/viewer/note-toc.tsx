import { EditorView } from "@codemirror/view";
import GithubSlugger from "github-slugger";
import { useMemo } from "react";
import { useActiveEditor } from "./editor/active-editor-context";

interface Heading {
	depth: number;
	text: string;
	id: string;
	/** Character offset of the heading line in `content`. */
	from: number;
}

// Line-based rather than a regex over the whole string with fences stripped:
// stripping shifts every offset after the first fence, and the offsets are what
// let a click scroll the EDITOR (which has no anchorable heading elements — see
// the click handler below). Fence state is tracked as we go so `# foo` inside a
// code block is still ignored.
function extractHeadings(markdown: string): Heading[] {
	const slugger = new GithubSlugger();
	const headings: Heading[] = [];
	const lines = markdown.split("\n");
	// An UNCLOSED fence must not hide every heading after it. Only skip a fenced
	// region that actually closes; a stray ``` (common mid-edit, and the welcome
	// note is edited on arrival) then costs nothing instead of blanking the
	// outline for the rest of the document.
	const fenceOpens = lines.filter((l) => /^\s*```/u.test(l)).length;
	const fencesBalanced = fenceOpens % 2 === 0;
	let offset = 0;
	let inFence = false;

	for (const line of lines) {
		if (fencesBalanced && /^\s*```/u.test(line)) {
			inFence = !inFence;
		} else if (!inFence) {
			const match = /^(?<hashes>#{1,6})\s+(?<text>.+?)\s*#*\s*$/u.exec(line);
			const hashes = match?.groups?.hashes ?? "";
			const text = (match?.groups?.text ?? "").trim();
			if (hashes && text && hashes.length <= 4) {
				headings.push({ depth: hashes.length, text, id: slugger.slug(text), from: offset });
			}
		}
		offset += line.length + 1;
	}
	return headings;
}

export default function NoteToc({ content }: { content: string }) {
	const headings = useMemo(() => extractHeadings(content), [content]);
	const { getView } = useActiveEditor();

	if (headings.length < 2) {
		return null;
	}

	// Reading view renders real headings with ids (rehype-slug), so the plain
	// `href="#slug"` scrolls natively. The EDITOR is a CodeMirror document with
	// no heading elements at all, so the hash landed in the URL and nothing
	// moved — and the editor is the default view. Scroll it explicitly.
	function scrollTo(heading: Heading) {
		const view = getView();
		if (!view) {
			return false;
		}
		const pos = Math.min(heading.from, view.state.doc.length);
		view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: "start" }) });
		return true;
	}

	return (
		<nav aria-label="Table of contents" className="text-sm">
			<header className="border-border border-b px-3 py-2">
				<p className="font-medium text-[10px] text-muted-foreground uppercase tracking-wide">
					On this page
				</p>
			</header>
			<ul className="space-y-px py-2">
				{headings.map((h) => (
					<li key={h.id}>
						<a
							href={`#${h.id}`}
							style={{ paddingLeft: `${0.75 + (h.depth - 1) * 0.75}rem` }}
							className="flex items-center gap-1 rounded px-1 py-0.5 text-foreground/80 hover:bg-muted hover:text-foreground"
							onClick={(e) => {
								// Only take over when an editor is mounted; otherwise let the
								// browser do its normal fragment scroll in reading view.
								if (scrollTo(h)) {
									e.preventDefault();
								}
							}}
						>
							<span className="truncate">{h.text}</span>
						</a>
					</li>
				))}
			</ul>
		</nav>
	);
}
