import GithubSlugger from "github-slugger";
import { useMemo } from "react";

interface Heading {
	depth: number;
	text: string;
	id: string;
}

function extractHeadings(markdown: string): Heading[] {
	const slugger = new GithubSlugger();
	const headings: Heading[] = [];
	// Strip fenced code blocks so `# foo` inside them isn't picked up.
	const stripped = markdown.replace(/```[\s\S]*?```/gu, "");
	const re = /^(#{1,6})\s+(.+?)\s*#*\s*$/gmu;
	let match: RegExpExecArray | null;
	while ((match = re.exec(stripped)) !== null) {
		const hashes = match[1] ?? "";
		const text = (match[2] ?? "").trim();
		const depth = hashes.length;
		if (depth <= 4 && text) {
			headings.push({ depth, text, id: slugger.slug(text) });
		}
	}
	return headings;
}

export default function NoteToc({ content }: { content: string }) {
	const headings = useMemo(() => extractHeadings(content), [content]);
	if (headings.length < 2) {
		return null;
	}

	return (
		<nav aria-label="Table of contents" className="text-sm">
			<header className="border-border border-b px-3 py-2">
				<p className="font-medium text-[10px] text-muted-foreground uppercase tracking-wide">
					On this page
				</p>
			</header>
			<ul role="list" className="space-y-px py-2">
				{headings.map((h, i) => (
					<li key={`${h.id}-${i}`}>
						<a
							href={`#${h.id}`}
							style={{ paddingLeft: `${0.75 + (h.depth - 1) * 0.75}rem` }}
							className="flex items-center gap-1 rounded px-1 py-0.5 text-foreground/80 hover:bg-muted hover:text-foreground"
						>
							<span className="truncate">{h.text}</span>
						</a>
					</li>
				))}
			</ul>
		</nav>
	);
}
