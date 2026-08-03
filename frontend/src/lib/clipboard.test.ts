import { afterEach, describe, expect, test, vi } from "vitest";
import { copyToClipboard } from "./clipboard";

const realClipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard");

function setClipboard(value: unknown) {
	Object.defineProperty(navigator, "clipboard", { value, configurable: true });
}

afterEach(() => {
	if (realClipboard) {
		Object.defineProperty(navigator, "clipboard", realClipboard);
	} else {
		setClipboard(undefined);
	}
	vi.restoreAllMocks();
});

describe("copyToClipboard", () => {
	test("uses the async clipboard API when it is available", async () => {
		const writeText = vi.fn().mockResolvedValue(undefined);
		setClipboard({ writeText });

		await expect(copyToClipboard("[[note]]")).resolves.toBe(true);
		expect(writeText).toHaveBeenCalledWith("[[note]]");
	});

	// The self-host case: a LAN box on plain http is a non-secure origin, where
	// the whole `navigator.clipboard` namespace is absent. Reaching through it
	// throws synchronously, so a caller's .catch() never sees the failure.
	test("falls back to execCommand when there is no clipboard namespace", async () => {
		setClipboard(undefined);
		const execCommand = vi.fn().mockReturnValue(true);
		document.execCommand = execCommand;

		await expect(copyToClipboard("[[note]]")).resolves.toBe(true);
		expect(execCommand).toHaveBeenCalledWith("copy");
	});

	test("falls back when the async API rejects", async () => {
		setClipboard({ writeText: vi.fn().mockRejectedValue(new Error("denied")) });
		const execCommand = vi.fn().mockReturnValue(true);
		document.execCommand = execCommand;

		await expect(copyToClipboard("[[note]]")).resolves.toBe(true);
		expect(execCommand).toHaveBeenCalled();
	});

	// Reporting a copy that did not happen is worse than reporting a failure —
	// the user walks away believing the link is on their clipboard.
	test("reports failure rather than throwing when nothing works", async () => {
		setClipboard(undefined);
		document.execCommand = vi.fn().mockReturnValue(false);

		await expect(copyToClipboard("[[note]]")).resolves.toBe(false);
	});
});
