import { render, screen, waitFor } from "@testing-library/react";
import { beforeAll, expect, it, vi } from "vitest";
import { chromeText } from "@/i18n/ui-chrome.testing";
import { ApiError, api } from "../api/client";
import AttachmentImg from "./attachment-img";

beforeAll(() => {
	// jsdom lacks createObjectURL/revokeObjectURL
	URL.createObjectURL = vi.fn(() => "blob:fake");
	URL.revokeObjectURL = vi.fn();
});

it("fetches the attachment with ?raw=1 and renders an img", async () => {
	const spy = vi
		.spyOn(api, "getBlob")
		.mockResolvedValueOnce(new Blob(["x"], { type: "image/png" }));
	render(<AttachmentImg path="img/a.png" alt="A" />);
	await waitFor(() => expect(screen.getByRole("img")).toBeInTheDocument());
	expect(spy).toHaveBeenCalledWith("/attachments/img/a.png?raw=1");
});

it('says "Missing attachment" only on a real 404', async () => {
	vi.spyOn(api, "getBlob").mockRejectedValueOnce(new ApiError(404, "not found"));
	render(<AttachmentImg path="img/a.png" />);
	await waitFor(() => expect(screen.getByText(/missing attachment/iu)).toBeInTheDocument());
});

it('does NOT claim "missing" on a transient 5xx — says temporarily unavailable', async () => {
	vi.spyOn(api, "getBlob").mockRejectedValueOnce(new ApiError(502, "storage down"));
	render(<AttachmentImg path="img/a.png" />);
	await waitFor(() => expect(screen.getByText(/temporarily unavailable/iu)).toBeInTheDocument());
	expect(screen.queryByText(/missing attachment/iu)).not.toBeInTheDocument();
});

// UI text inside the note body: the i18n leak scan reads only marked chrome there.
// The path is the user's own text, so only our words around it are marked.
it("marks its fallbacks as UI chrome, not the path", async () => {
	vi.spyOn(api, "getBlob").mockRejectedValueOnce(new ApiError(404, "not found"));
	const { container } = render(<AttachmentImg path="img/a.png" />);
	expect(chromeText(container)).toBe("Loading …");
	await waitFor(() => expect(chromeText(container)).toBe("Missing attachment: "));
	expect(container.textContent).toBe("Missing attachment: img/a.png");
});
