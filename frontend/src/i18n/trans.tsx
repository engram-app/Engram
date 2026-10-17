import { Fragment, type ReactNode } from "react";
import { useT } from "./locale-provider";
import type { Key } from "./translate";

// split() with a capture group puts slot names at odd indexes.
function splitSlots(translated: string): string[] {
	return translated.split(/\{(?<slot>\w+)\}/u);
}

// Renders one translated sentence around React children, so a styled span or
// link can sit anywhere the target language needs it. Slot names must be
// unique within one sentence.
// `text` takes the same keys as the translate function: a literal or a msg() key.
// `chrome`: the sentence sits inside a note body, where the i18n leak scan
// reads only `data-ui-chrome` text, so our words are marked and the slots
// (the user's or a third party's text) are not.
export function Trans<K extends string>({
	text,
	slots,
	chrome = false,
}: {
	text: Key<K>;
	slots: Record<string, ReactNode>;
	chrome?: boolean;
}) {
	const { t } = useT();
	const parts = splitSlots(t(text));
	return (
		<>
			{parts.map((part, index) => {
				if (index % 2 === 1) {
					return <Fragment key={part}>{slots[part] ?? `{${part}}`}</Fragment>;
				}
				// Keyed by the slot it precedes: slot names are unique per sentence.
				return chrome && part ? (
					<span key={`before:${parts[index + 1] ?? ""}`} data-ui-chrome>
						{part}
					</span>
				) : (
					part
				);
			})}
		</>
	);
}

/** `Trans chrome` for DOM widgets (CodeMirror): fills `el` with an already
 *  translated sentence, our words marked `data-ui-chrome`, slots unmarked. */
export function fillChromeText(
	el: HTMLElement,
	translated: string,
	slots: Record<string, Node | string>,
): void {
	el.replaceChildren(
		...splitSlots(translated).flatMap((part, index): (Node | string)[] => {
			if (index % 2 === 1) {
				return [slots[part] ?? `{${part}}`];
			}
			if (!part) {
				return [];
			}
			const span = document.createElement("span");
			span.dataset.uiChrome = "";
			span.textContent = part;
			return [span];
		}),
	);
}
