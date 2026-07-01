import { useEffect, useRef, useState } from "react";

let mermaidPromise: Promise<typeof import("mermaid").default> | null = null;

function loadMermaid() {
	if (!mermaidPromise) {
		mermaidPromise = import("mermaid").then((m) => {
			m.default.initialize({ startOnLoad: false, theme: "default", securityLevel: "strict" });
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

	useEffect(() => {
		let cancelled = false;
		loadMermaid()
			.then((mermaid) => mermaid.render(id, code))
			.then(({ svg }) => {
				if (cancelled || !ref.current) return;
				ref.current.innerHTML = svg;
				setError(null);
			})
			.catch((err) => {
				if (!cancelled) setError(err?.message ?? String(err));
			});
		return () => {
			cancelled = true;
		};
	}, [code, id]);

	if (error) {
		return (
			<pre className="rounded border border-red-300 bg-red-50 p-3 text-xs text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
				Mermaid error: {error}
				{"\n\n"}
				{code}
			</pre>
		);
	}

	return <div ref={ref} className="mermaid my-4 flex justify-center" />;
}
