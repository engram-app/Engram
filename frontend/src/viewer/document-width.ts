// How wide the white document column is allowed to grow. Saved per browser:
// it is a reading preference, not note data.
export const DEFAULT_DOCUMENT_WIDTH = 840;
export const MIN_DOCUMENT_WIDTH = 480;
export const MAX_DOCUMENT_WIDTH = 2000;
export const DOCUMENT_WIDTH_KEY = "engram.documentWidth";

/** Whole pixels inside the allowed range; anything that is not a number gets the default. */
export function clampDocumentWidth(width: number): number {
	if (!Number.isFinite(width)) {
		return DEFAULT_DOCUMENT_WIDTH;
	}
	return Math.min(MAX_DOCUMENT_WIDTH, Math.max(MIN_DOCUMENT_WIDTH, Math.round(width)));
}

export function readDocumentWidth(): number {
	try {
		const raw = localStorage.getItem(DOCUMENT_WIDTH_KEY);
		if (raw === null || raw.trim() === "") {
			return DEFAULT_DOCUMENT_WIDTH;
		}
		return clampDocumentWidth(Number(raw));
	} catch {
		return DEFAULT_DOCUMENT_WIDTH;
	}
}

/** `null` forgets the saved width, returning to the default. */
export function writeDocumentWidth(width: number | null): void {
	try {
		if (width === null) {
			localStorage.removeItem(DOCUMENT_WIDTH_KEY);
		} else {
			localStorage.setItem(DOCUMENT_WIDTH_KEY, String(clampDocumentWidth(width)));
		}
	} catch {
		// ignore — private browsing, etc. The width just will not persist.
	}
}
