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
