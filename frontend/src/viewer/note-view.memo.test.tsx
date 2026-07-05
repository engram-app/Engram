import { fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import type { EngramConfig } from "../config";
import { ConfigProvider } from "../config-context";
import NoteView from "./note-view";

// NoteView reads useIsFreeTier() -> useConfig(); mount a minimal config.
const testConfig: EngramConfig = {
	authProvider: "clerk",
	clerkPublishableKey: "",
	billingEnabled: true,
	clerkWaitlistMode: false,
	apiBase: "",
	wsBase: "",
	tracingEnabled: false,
};

// Counts actual ReactMarkdown renders — each one is a full remark/rehype
// parse of the note in production, the dominant typing-latency cost.
let markdownRenders = 0;

vi.mock("react-markdown", () => ({
	default: ({ children }: { children: string }) => {
		markdownRenders++;
		return <div data-testid="md">{children}</div>;
	},
	defaultUrlTransform: (url: string) => url,
}));

vi.mock("../api/queries", () => ({
	useBillingStatus: () => ({ data: { tier: "pro" } }),
}));

vi.mock("./attachment-img", () => ({ default: () => null }));
vi.mock("./mermaid-block", () => ({ default: () => null }));

const EMPTY_TAGS: string[] = [];

// Simulates NotePage while typing: parent state changes every keystroke,
// but the preview's props stay referentially identical.
function Harness() {
	const [, setTick] = useState(0);
	return (
		<>
			<button type="button" onClick={() => setTick((t) => t + 1)}>
				tick
			</button>
			<NoteView content="# Hello" tags={EMPTY_TAGS} />
		</>
	);
}

describe("NoteView memoization", () => {
	it("does not re-run the markdown pipeline when parent re-renders with identical props", () => {
		markdownRenders = 0;
		render(
			<ConfigProvider config={testConfig}>
				<Harness />
			</ConfigProvider>,
		);
		expect(markdownRenders).toBe(1);

		fireEvent.click(screen.getByText("tick"));
		fireEvent.click(screen.getByText("tick"));

		expect(markdownRenders).toBe(1);
	});
});
