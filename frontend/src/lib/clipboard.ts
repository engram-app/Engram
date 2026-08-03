/**
 * Copy text, degrading to the legacy path where the async API is unavailable.
 *
 * `navigator.clipboard` does not exist on a NON-SECURE ORIGIN, which is the
 * normal case for self-host: a box on the LAN served over plain http. Reaching
 * straight for `navigator.clipboard.writeText` there throws a synchronous
 * TypeError off the undefined namespace — a `.catch()` on the call never runs,
 * because no promise was ever created — so the copy did not merely fail, it
 * escaped as an uncaught error.
 *
 * Returns whether the text landed, rather than throwing, so callers can report
 * honestly instead of claiming success they cannot see.
 */
export async function copyToClipboard(text: string): Promise<boolean> {
	if (navigator.clipboard?.writeText) {
		try {
			await navigator.clipboard.writeText(text);
			return true;
		} catch {
			// Permission denied or a non-focused document — the legacy path below
			// is still worth a try.
		}
	}

	try {
		const ta = document.createElement("textarea");
		ta.value = text;
		ta.setAttribute("readonly", "");
		ta.style.position = "fixed";
		ta.style.top = "0";
		ta.style.left = "0";
		ta.style.opacity = "0";
		document.body.appendChild(ta);
		ta.select();
		const ok = document.execCommand("copy");
		document.body.removeChild(ta);
		return ok;
	} catch {
		return false;
	}
}
