import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { FeedbackDialog, feedbackArea } from "./feedback-dialog";

const { post } = vi.hoisted(() => ({ post: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { get: vi.fn(), post, patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));

let qc: QueryClient;

beforeEach(() => {
	post.mockReset();
	qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } });
});

function Wrapper({ children }: { children: ReactNode }) {
	return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
}

describe("FeedbackDialog", () => {
	it("keeps Send disabled until something is typed", () => {
		render(<FeedbackDialog open onOpenChange={vi.fn()} />, { wrapper: Wrapper });
		const send = screen.getByRole("button", { name: /send/iu });
		expect(send).toBeDisabled();
		fireEvent.change(screen.getByRole("textbox"), { target: { value: "   " } });
		expect(send).toBeDisabled();
	});

	it("sends the message and closes", async () => {
		post.mockResolvedValue({ status: "ok" });
		const onOpenChange = vi.fn();
		render(<FeedbackDialog open onOpenChange={onOpenChange} />, { wrapper: Wrapper });

		fireEvent.change(screen.getByRole("textbox"), { target: { value: "search misses tags" } });
		fireEvent.click(screen.getByRole("button", { name: /send/iu }));

		await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false));
		expect(post).toHaveBeenCalledWith("/feedback", {
			kind: "general",
			message: "search misses tags",
			contact_ok: false,
			source: "web",
			area: "home",
		});
	});

	it("sends the picked category, mood and reply consent", async () => {
		post.mockResolvedValue({ status: "ok" });
		const onOpenChange = vi.fn();
		render(<FeedbackDialog open onOpenChange={onOpenChange} />, { wrapper: Wrapper });

		fireEvent.click(screen.getByRole("radio", { name: /bug/iu }));
		fireEvent.click(screen.getByRole("radio", { name: /2 of 5/iu }));
		fireEvent.click(screen.getByRole("checkbox", { name: /email me/iu }));
		fireEvent.change(screen.getByRole("textbox"), { target: { value: "sync broke" } });
		fireEvent.click(screen.getByRole("button", { name: /send/iu }));

		await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false));
		expect(post).toHaveBeenCalledWith(
			"/feedback",
			expect.objectContaining({ category: "bug", mood: 2, contact_ok: true }),
		);
	});

	it("stays open and keeps the text when sending fails", async () => {
		post.mockRejectedValue(new Error("boom"));
		const onOpenChange = vi.fn();
		render(<FeedbackDialog open onOpenChange={onOpenChange} />, { wrapper: Wrapper });

		fireEvent.change(screen.getByRole("textbox"), { target: { value: "sync broke" } });
		fireEvent.click(screen.getByRole("button", { name: /send/iu }));

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(onOpenChange).not.toHaveBeenCalled();
		expect(screen.getByRole("textbox")).toHaveValue("sync broke");
	});
});

describe("feedbackArea", () => {
	it("keeps the settings section", () => {
		expect(feedbackArea("/v/my-vault", "#settings/billing")).toBe("settings/billing");
		expect(feedbackArea("/v/my-vault", "#settings/account/extra")).toBe("settings/account");
	});

	it("never sends the vault slug, the note path or a heading anchor", () => {
		expect(feedbackArea("/v/secret-vault", "")).toBe("vault");
		expect(feedbackArea("/v/secret-vault/Private/Diary.md", "#my-heading")).toBe("note");
	});

	it("names other pages by their first segment", () => {
		expect(feedbackArea("/onboard/about", "")).toBe("onboard");
		expect(feedbackArea("/", "")).toBe("home");
	});
});
