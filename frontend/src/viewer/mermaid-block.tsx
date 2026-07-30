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

	if (error) {
		return (
			<pre className="rounded border border-red-300 bg-red-50 p-3 text-red-700 text-xs dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
				Mermaid error: {error}
				\n\n
				{code}
			</pre>
		);
	}

	return <div ref={ref} className="mermaid my-4 flex justify-center" />;
}
