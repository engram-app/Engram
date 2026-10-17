import { useLayoutEffect, useRef, useState } from "react";
import { Trans } from "@/i18n/trans";
import { useTheme } from "../theme/theme-provider";
import { drawMermaid } from "./mermaid-render";

export default function MermaidBlock({ code }: { code: string }) {
	const ref = useRef<HTMLDivElement>(null);
	const [error, setError] = useState<string | null>(null);
	const { resolved } = useTheme();

	// Keyed on `resolved`: switching light/dark has to re-draw, because the
	// palette is baked into the SVG rather than applied as CSS. A layout effect
	// so drawMermaid's height reservation is in place before the first paint.
	useLayoutEffect(() => {
		const target = ref.current;
		if (!target) {
			return;
		}
		return drawMermaid(target, "reading", code, resolved === "dark", {
			drawn: () => setError(null),
			failed: (err) => setError(err instanceof Error ? err.message : String(err)),
		});
	}, [code, resolved]);

	// The target div stays MOUNTED even while erroring, rather than being swapped
	// for the <pre>. Returning early on error unmounted it, so `ref.current` was
	// null on the next run — and the success path bails on a null ref before it
	// can clear the error. Net effect: fix your diagram's syntax and the block
	// stayed frozen on the old parse error forever, because NoteView renders this
	// without a `key` so React reuses the instance instead of remounting. The
	// user's reasonable conclusion is that their correction is also wrong.
	return (
		<>
			{error ? (
				<pre className="rounded border border-red-300 bg-red-50 p-3 text-red-700 text-xs dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
					{/* Mermaid's parse error is third-party English: verbatim, tagged as such. */}
					<Trans
						chrome
						text="Mermaid error: {error}"
						slots={{ error: <span lang="en">{error}</span> }}
					/>
					{`\n\n${code}`}
				</pre>
			) : null}
			<div ref={ref} className={`mermaid my-4 justify-center ${error ? "hidden" : "flex"}`} />
		</>
	);
}
