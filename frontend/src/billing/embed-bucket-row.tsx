import { useEmbedBucket } from "@/api/queries";
import { useT } from "@/i18n/locale-provider";
import { intlLocale } from "@/lib/intl-locale";

// Free's indexing budget, shown so the limit is never invisible: what is left
// and when it is full again. Renders nothing for a user with no bucket (paid,
// self-host).
export default function EmbedBucketRow() {
	const { t, renderedLocale } = useT();
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
						? t("Refills {perDay} a day, full again on {date}", {
								perDay: num.format(bucket.refill_per_day),
								date: new Date(bucket.full_at).toLocaleDateString(localeTag),
							})
						: t("Full")}
				</small>
				{bucket.available === 0 && (
					<small className="block font-normal text-muted-foreground">
						{t(
							"New notes are searchable by keyword now and get full search as your budget refills.",
						)}
					</small>
				)}
			</dd>
		</dl>
	);
}
