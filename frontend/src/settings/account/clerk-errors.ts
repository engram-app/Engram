import { isClerkAPIResponseError } from "@clerk/react/errors";
import { type UIText, untranslated } from "@/i18n/ui-text";

// Surface Clerk's actual validation message instead of a generic fallback.
// Clerk API errors carry errors[].longMessage/message (e.g. a 422 explaining
// which field the instance rejected); without this they get swallowed.
// Clerk API errors arrive in English (only Clerk's own components are localized),
// so the server text is shown as-is and our fallback is translated.
export function clerkErrorMessage(e: unknown, fallback: UIText): UIText {
	if (isClerkAPIResponseError(e)) {
		const [first] = e.errors;
		const server = first?.longMessage ?? first?.message;
		return server === undefined ? fallback : untranslated(server);
	}
	return fallback;
}
