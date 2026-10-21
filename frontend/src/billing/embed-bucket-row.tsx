import { useEmbedBucket } from "@/api/queries";
import { useT } from "@/i18n/locale-provider";
import { intlLocale } from "@/lib/intl-locale";

// Free's indexing budget, shown so the limit is never invisible: what is left,
// when it is full again, and how many notes wait on it keyword-only. Renders nothing for a user with no bucket (paid,
// self-host).
export default function EmbedBucketRow() {
	const { t, tn, renderedLocale } = useT();
	const { data: bucket } = useEmbedBucket();
	if (!bucket) {
		return null;
	}
	const localeTag = intlLocale(renderedLocale);
	const num = new Intl.NumberFormat(localeTag);

	return (
		<dl className="grid grid-cols-2 gap-4 text-sm">
			<dt className="text-muted-foreground">{t("Indexing budget")}</dt>
			<dd className="font-medium">
				{t("{available} of {capacity} tokens left", {
					available: num.format(bucket.available),
					capacity: num.format(bucket.capacity),
				})}
				<small className="block font-normal text-muted-foreground">
					{bucket.full_at
						? t("Refills {perDay} tokens a day. Full again on {date}.", {
								perDay: num.format(bucket.refill_per_day),
								date: new Date(bucket.full_at).toLocaleDateString(localeTag),
							})
						: t("All tokens are available.")}
				</small>
				{bucket.parked_notes > 0 && (
					<small className="block font-normal text-muted-foreground">
						{bucket.parked_ready_at
							? tn(
									{
										one: "{count} note has keyword search only, until {date}.",
										other: "{count} notes have keyword search only, until {date}.",
									},
									bucket.parked_notes,
									{ date: new Date(bucket.parked_ready_at).toLocaleDateString(localeTag) },
								)
							: tn(
									{
										one: "{count} note has keyword search only, until the budget refills.",
										other: "{count} notes have keyword search only, until the budget refills.",
									},
									bucket.parked_notes,
								)}
					</small>
				)}
			</dd>
		</dl>
	);
}
