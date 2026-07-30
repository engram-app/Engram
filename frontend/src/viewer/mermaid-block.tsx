import { useEffect, useRef, useState } from "react";
import { useTheme } from "../theme/theme-provider";
import { nextMermaidId, renderMermaid } from "./mermaid-render";

export default function MermaidBlock({ code }: { code: string }) {
	const ref = useRef<HTMLDivElement>(null);
	const [error, setError] = useState<string | null>(null);
	const [id] = useState(nextMermaidId);
	const { resolved } = useTheme();

	useEffect(() => {
		let cancelled = false;
		// Keyed on `resolved`: switching light/dark has to re-draw, because the
		// palette is baked into the SVG rather than applied as CSS.
		renderMermaid(id, code, resolved === "dark")
			.then((svg) => {
				if (cancelled || !ref.current) {
					return;
				}
				ref.current.innerHTML = svg;
				setError(null);
			})
			.catch((err) => {
				if (!cancelled) {
					setError(err?.message ?? String(err));
				}
			});
		return () => {
			cancelled = true;
		};
	}, [code, id, resolved]);

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
					{`Mermaid error: ${error}\n\n${code}`}
				</pre>
			) : null}
			<div ref={ref} className={`mermaid my-4 justify-center ${error ? "hidden" : "flex"}`} />
		</>
	);
}
