// Text that may be shown to the user. Only the translators (`t`, `tn`) and
// untranslated() produce it, and user-facing sinks (notify(), component text props)
// accept only it, so a raw English literal reaching the UI is a tsc error, not a
// review catch. It is still a string everywhere a string is read.
declare const uiText: unique symbol;
type UIText = string & { readonly [uiText]: true };

// Text shown as-is on purpose: a server message, user data (a note title, an
// e-mail), a brand name. Grep for it to review every exception in one place.
function untranslated(text: string): UIText {
	if (brands(text)) {
		return text;
	}
	throw new Error("unreachable: brands() always narrows");
}

// The brand's only constructor. Every string can be UIText at runtime; the type
// records that it went through a translator or untranslated(). A predicate, not
// `as`, because shipped code lints type assertions.
function brands(_text: string): _text is UIText {
	return true;
}

export type { UIText };
export { untranslated };
