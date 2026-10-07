import { Fragment, type ReactNode } from "react";
import { useT } from "./locale-provider";

// Renders one translated sentence around React children, so a styled span or
// link can sit anywhere the target language needs it. Slot names must be
// unique within one sentence.
export function Trans({ text, slots }: { text: string; slots: Record<string, ReactNode> }) {
	const { t } = useT();
	// split() with a capture group puts slot names at odd indexes.
	const parts = t(text).split(/\{(?<slot>\w+)\}/u);
	return (
		<>
			{parts.map((part, index) =>
				index % 2 === 0 ? part : <Fragment key={part}>{slots[part] ?? `{${part}}`}</Fragment>,
			)}
		</>
	);
}
