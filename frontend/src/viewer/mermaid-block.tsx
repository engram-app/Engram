import { useEffect, useRef, useState } from "react";
import { useTheme } from "../theme/theme-provider";

let mermaidPromise: Promise<typeof import("mermaid").default> | null = null;

// Theme is NOT set here. Mermaid bakes the palette into the SVG at render time,
// so a module-level `theme: "default"` drew dark-on-transparent diagrams that
// were unreadable in dark mode. `initialize` is idempotent and merges, so the
// effect below re-applies the palette before each render instead.
function loadMermaid() {
	if (!mermaidPromise) {
		mermaidPromise = import("mermaid").then((m) => {
			m.default.initialize({ startOnLoad: false, securityLevel: "strict" });
			return m.default;
		});
	}
	return mermaidPromise;
}

let idCounter = 0;

export default function MermaidBlock({ code }: { code: string }) {
	const ref = useRef<HTMLDivElement>(null);
	const [error, setError] = useState<string | null>(null);
	const [id] = useState(() => `mermaid-${++idCounter}`);
	const { resolved } = useTheme();

	useEffect(() => {
		let cancelled = false;
		loadMermaid()
			.then((mermaid) => {
				// Re-apply before every render: the palette is baked into the SVG, so
				// switching light/dark has to re-draw rather than restyle. Keying the
				// effect on `resolved` is what makes that happen.
				mermaid.initialize({
					startOnLoad: false,
					securityLevel: "strict",
					theme: resolved === "dark" ? "dark" : "default",
				});
				return mermaid.render(id, code);
			})
			.then(({ svg }) => {
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
