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

// A catalog key marked by msg() in a module-scope constant, not yet translated:
// render it with t(). Fields that hold one take MsgKey, so a raw literal there
// (invisible to the key scanner, so never translated) is a tsc error too.
declare const msgKey: unique symbol;
type MsgKey = string & { readonly [msgKey]: true };

function asMsgKey(en: string): MsgKey {
	if (marks(en)) {
		return en;
	}
	throw new Error("unreachable: marks() always narrows");
}

function marks(_en: string): _en is MsgKey {
	return true;
}

export type { MsgKey, UIText };
export { asMsgKey, untranslated };
