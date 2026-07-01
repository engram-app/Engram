// Paddle returns money as a string in the currency's minor units ("2000" =
// $20.00 for USD, but ¥2000 for the zero-decimal JPY). Derive the minor-unit
// digit count from Intl so we handle 0-, 2-, and 3-decimal currencies without
// a hardcoded table, then format in the caller's locale.
export function formatMoney(
	minorUnits: string | null | undefined,
	currency: string | null | undefined,
	locale?: string,
): string | null {
	if (minorUnits == null || currency == null) return null;

	const amount = Number(minorUnits);
	if (Number.isNaN(amount)) return null;

	const digits =
		new Intl.NumberFormat("en", { style: "currency", currency }).resolvedOptions()
			.maximumFractionDigits ?? 2;

	const major = amount / 10 ** digits;

	return new Intl.NumberFormat(locale, { style: "currency", currency }).format(major);
}
