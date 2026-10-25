import { msg } from "@/i18n/msg";
import type { Translate } from "@/i18n/translate";
import type { MsgKey } from "@/i18n/ui-text";

// Subscription and transaction statuses arrive as snake_case enum values. Known
// ones get a translated lowercase label (CSS capitalizes it on screen); an
// unknown status gets a translated generic label, never the raw wire value.
const STATUS_LABELS: Record<string, MsgKey> = {
	active: msg("active"),
	trialing: msg("trialing"),
	past_due: msg("past due"),
	paused: msg("paused"),
	canceled: msg("canceled"),
	completed: msg("completed"),
	billed: msg("billed"),
	paid: msg("paid"),
	ready: msg("ready"),
	draft: msg("draft"),
};

export function statusLabel(status: string, t: Translate): string {
	const label = STATUS_LABELS[status];
	return t(label ?? msg("Unknown"));
}
