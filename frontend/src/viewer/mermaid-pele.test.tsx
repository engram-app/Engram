import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import MermaidBlock from "./mermaid-block";
import { renderMermaid } from "./mermaid-render";

// The real Pele, counted.
const calls = vi.hoisted(() => ({ n: 0 }));
vi.mock("pele/lazy", async (importOriginal) => {
	const real = await importOriginal<typeof import("pele/lazy")>();
	return {
		...real,
		renderAsync: (...args: Parameters<typeof real.renderAsync>) => {
			calls.n++;
			return real.renderAsync(...args);
		},
	};
});

const CODE = "flowchart LR\n  A --> B";

vi.mock("@/lib/once-visible", () => ({
	onceVisible: (_el: Element, run: () => void) => {
		run();
		return () => undefined;
	},
}));

describe("mermaid on Pele", () => {
	it("draws a real diagram as a themeable .pele SVG, with no script or handler in it", async () => {
		const svg = await renderMermaid(
			'flowchart LR\n  A["<img src=x onerror=alert(1)>"] --> B[done]',
		);
		expect(svg).toContain('class="pele');
		expect(svg).not.toMatch(/<script|onerror=|<img/iu);
	});

	it("a light/dark flip recolours through CSS: the diagram is drawn once", async () => {
		calls.n = 0;
		const { container, rerender } = render(<MermaidBlock code={CODE} />);
		await vi.waitFor(() => expect(container.querySelector("svg")).not.toBeNull());
		document.documentElement.classList.add("dark");
		rerender(<MermaidBlock code={CODE} />);
		document.documentElement.classList.remove("dark");
		rerender(<MermaidBlock code={CODE} />);
		expect(calls.n).toBe(1);
	});
});
