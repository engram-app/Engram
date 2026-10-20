import { ApiError, LimitExceededError } from "@/api/client";
import type { Translate } from "@/i18n/translate";
import type { UIText } from "@/i18n/ui-text";

export interface UploadFailure {
	text: UIText;
	/** Set when raising the plan fixes it: the reason the upgrade dialog explains. */
	upgradeReason?: string;
	/** True when sending the same file again can work. */
	retry?: boolean;
}

// instanceof can fail across module copies (tests, HMR), so fall back to the name.
const isLimit = (err: unknown): err is LimitExceededError =>
	err instanceof LimitExceededError || (err instanceof Error && err.name === "LimitExceededError");
const isApi = (err: unknown): err is ApiError =>
	err instanceof ApiError || (err instanceof Error && err.name === "ApiError");

/** The one mapping from an upload error to what the user is told and offered. */
export function uploadFailure(err: unknown, t: Translate): UploadFailure {
	if (isLimit(err)) {
		switch (err.reason) {
			case "attachments_disabled":
				return { text: t("Upgrade to upload attachments"), upgradeReason: err.reason };
			case "attachment_must_be_text":
				return { text: t("Free tier: text files only"), upgradeReason: err.reason };
			case "file_too_large":
				return { text: t("This file is over your plan's size limit."), upgradeReason: err.reason };
			case "attachments_quota_exceeded":
				return { text: t("Your storage is full."), upgradeReason: err.reason };
			default:
				return { text: t("Upgrade required"), upgradeReason: err.reason };
		}
	}
	if (isApi(err) && err.status === 415) {
		return { text: t("Executable files don't sync.") };
	}
	return { text: t("Upload failed. Try again."), retry: true };
}
