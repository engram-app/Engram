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

// Paddle returns money as a string in the currency's minor units ("2000" =
// $20.00 for USD, but ¥2000 for the zero-decimal JPY). Derive the minor-unit
// digit count from Intl so we handle 0-, 2-, and 3-decimal currencies without
// a hardcoded table, then format in the caller's locale.
export function formatMoney(
	minorUnits: string | null | undefined,
	currency: string | null | undefined,
	locale?: string,
): string | null {
	if (
		minorUnits === null ||
		minorUnits === undefined ||
		currency === null ||
		currency === undefined
	) {
		return null;
	}

	const amount = Number(minorUnits);
	if (Number.isNaN(amount)) {
		return null;
	}

	const digits =
		new Intl.NumberFormat("en", { style: "currency", currency }).resolvedOptions()
			.maximumFractionDigits ?? 2;

	const major = amount / 10 ** digits;

	return new Intl.NumberFormat(locale, { style: "currency", currency }).format(major);
}

// A plan price in US dollars, written by Intl for the reader's locale ("$7",
// "5,83 $"). Kept out of translated sentences: a model given "{price}/mo billed
// yearly" decorated the amount with a currency of its own ("$5.83 руб./мес.").
export function formatUsd(amount: number, locale?: string): string {
	return new Intl.NumberFormat(locale, {
		style: "currency",
		currency: "USD",
		minimumFractionDigits: Number.isInteger(amount) ? 0 : 2,
	}).format(amount);
}

export function statusLabel(status: string, t: Translate): string {
	const label = STATUS_LABELS[status];
	return t(label ?? msg("Unknown"));
}
