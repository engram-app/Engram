import { isClerkAPIResponseError } from "@clerk/react/errors";

// Surface Clerk's actual validation message instead of a generic fallback.
// Clerk API errors carry errors[].longMessage/message (e.g. a 422 explaining
// which field the instance rejected); without this they get swallowed.
export function clerkErrorMessage(e: unknown, fallback: string): string {
	if (isClerkAPIResponseError(e)) {
		const first = e.errors[0];
		return first?.longMessage ?? first?.message ?? fallback;
	}
	return fallback;
}
