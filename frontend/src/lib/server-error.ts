import { ApiError } from "@/api/client";
import { msg } from "@/i18n/msg";
import type { Translate } from "@/i18n/translate";
import type { MsgKey, UIText } from "@/i18n/ui-text";

// API error codes (the `error` field) worth their own sentence. The server writes
// English, so its text is never shown: an unlisted code gets the caller's fallback.
const BY_CODE: Record<string, MsgKey> = {
	last_admin: msg("Can't remove the last admin."),
	invalid_invite: msg("Check the invite's label, uses and expiry, then try again."),
	invalid_password: msg("Incorrect password."),
};

const BY_STATUS: Record<number, MsgKey> = {
	403: msg("You don't have permission to do that."),
	429: msg("Too many requests. Try again in a moment."),
};

// The translated message for a failed request, for the UI boundary.
export function serverErrorMessage(e: unknown, fallback: UIText, t: Translate): UIText {
	if (!(e instanceof ApiError)) {
		return fallback;
	}
	const key = BY_CODE[e.message] ?? BY_STATUS[e.status];
	return key ? t(key) : fallback;
}
