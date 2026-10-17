/** What the i18n e2e leak scan reads inside a note body: the text under
 *  `[data-ui-chrome]` (e2e/support/i18n-leaks.ts). Tests assert it is exactly
 *  our translated words, never the user's or a third party's text. */
export function chromeText(root: Element): string {
	const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
	let out = "";
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		if (node.parentElement?.closest("[data-ui-chrome]")) {
			out += node.textContent ?? "";
		}
	}
	return out;
}
