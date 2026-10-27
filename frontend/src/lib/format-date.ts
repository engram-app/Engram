const NUMERIC_DATE: Intl.DateTimeFormatOptions = {
	year: "numeric",
	month: "2-digit",
	day: "2-digit",
};

// Short calendar date ("Oct 4, 2026") for an ISO timestamp. `locale`
// defaults to the runtime's; billing passes "en-US" to match its currency
// formatting.
export function formatDate(iso: string, locale?: string): string {
	return new Intl.DateTimeFormat(locale, {
		year: "numeric",
		month: "short",
		day: "numeric",
	}).format(new Date(iso));
}

/**
 * A `date` or `datetime` property value as the native date inputs show it
 * ("06/30/2026", "06/30/2026, 2:05 PM"), for the at-rest property cell. A
 * date-only value is read as a LOCAL calendar day: `new Date("2026-06-30")`
 * is UTC midnight, which is the day before west of Greenwich. Anything that
 * does not parse is returned as stored.
 */
export function formatPropertyDate(
	value: string,
	type: "date" | "datetime",
	locale?: string,
): string {
	const day = /^(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})$/.exec(value)?.groups;
	const date = day ? new Date(Number(day.y), Number(day.m) - 1, Number(day.d)) : new Date(value);
	if (Number.isNaN(date.getTime())) {
		return value;
	}
	const opts: Intl.DateTimeFormatOptions =
		type === "datetime" && !day
			? { ...NUMERIC_DATE, hour: "numeric", minute: "2-digit" }
			: NUMERIC_DATE;
	return new Intl.DateTimeFormat(locale, opts).format(date);
}
