import { Link } from "react-router";
import { useT } from "@/i18n/locale-provider";
import type { UIText } from "@/i18n/ui-text";
import {
	type BillingUsage,
	type UsageEntry,
	useBillingUsage,
} from "../api/queries";
import { SettingsSectionCard } from "../settings/account/section-card";

// No invisible limits (review H3 of #2067): the notes cap and the v5 search
// passage budget are shown where they are spent, and a banner says what
// happens before and after either one binds. "Passages" are search points;
// past the passage budget older notes drop to keyword-only search (the floor
// tier), and nothing is deleted.

const WARN_AT = 0.8;

function percent(entry: UsageEntry | undefined): number | null {
	return entry?.limit ? Math.floor((100 * entry.used) / entry.limit) : null;
}

type T = ReturnType<typeof useT>;

function notices(usage: BillingUsage["usage"], { t, tn }: Pick<T, "t" | "tn">): UIText[] {
	const out: UIText[] = [];
	const { notes, index_points: points } = usage;
	const notesPct = percent(notes);

	if (notes.limit && notes.used >= notes.limit) {
		out.push(
			t(
				"You have reached your {cap} notes. New notes stop syncing until you upgrade or remove some.",
				{
					cap: notes.limit,
				},
			),
		);
	} else if (notesPct !== null && notesPct >= WARN_AT * 100) {
		out.push(
			t(
				"You have used {percent}% of your {cap} notes. At {cap}, new notes stop syncing until you upgrade or remove some.",
				{ percent: notesPct, cap: notes.limit ?? 0 },
			),
		);
	}

	const pointsPct = percent(points);

	const floor = usage.floor_notes ?? 0;

	if (floor > 0) {
		out.push(
			tn(
				{
					one: "Your full-search passages are used up. {count} older note is found by keyword only (exact words, not meaning). Nothing is deleted. Upgrade to bring full search back.",
					other:
						"Your full-search passages are used up. {count} older notes are found by keyword only (exact words, not meaning). Nothing is deleted. Upgrade to bring full search back.",
				},
				floor,
			),
		);
	} else if (pointsPct !== null && pointsPct >= WARN_AT * 100) {
		out.push(
			t(
				"You have used {percent}% of your {cap} full-search passages. Past that, older notes are found by keyword only (exact words, not meaning). Nothing is deleted.",
				{ percent: pointsPct, cap: points?.limit ?? 0 },
			),
		);
	}

	return out;
}

function Banner() {
	const { t, tn } = useT();
	const { data } = useBillingUsage();
	if (!data) {
		return null;
	}
	const lines = notices(data.usage, { t, tn });
	if (lines.length === 0) {
		return <span hidden data-testid="usage-banner-ready" />;
	}
	return (
		<aside
			role="status"
			className="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 bg-amber-50 px-4 py-2 text-amber-950 text-sm dark:bg-amber-950/40 dark:text-amber-100"
		>
			<ul>
				{lines.map((line) => (
					<li key={line}>{line}</li>
				))}
			</ul>
			<Link to={{ hash: "#settings/billing" }} className="font-medium underline underline-offset-4">
				{t("See usage")}
			</Link>
		</aside>
	);
}

function Panel() {
	const { t, tn } = useT();
	const { data } = useBillingUsage();
	if (!data) {
		return null;
	}
	const { notes, index_points: points, floor_notes: floor = 0 } = data.usage;

	return (
		<SettingsSectionCard title={t("Usage")}>
			<ul className="space-y-2 text-sm">
				<li>
					{notes.limit === null
						? t("Notes: {used}", { used: notes.used })
						: t("Notes: {used} of {cap}", { used: notes.used, cap: notes.limit })}
				</li>
				{!points || points.limit === null ? null : (
					<li>
						{t("Full search: {used} of {cap} passages", { used: points.used, cap: points.limit })}
						<p className="text-muted-foreground">
							{t(
								"A passage is one searchable piece of a note. Past this, older notes are found by keyword only (exact words, not meaning). Nothing is deleted.",
							)}
						</p>
					</li>
				)}
				{floor > 0 ? (
					<li>
						{tn(
							{
								one: "{count} note is found by keyword only (exact words, not meaning).",
								other: "{count} notes are found by keyword only (exact words, not meaning).",
							},
							floor,
						)}
					</li>
				) : null}
			</ul>
		</SettingsSectionCard>
	);
}

export function UsageBanner() {
	return <Banner />;
}

export function UsagePanel() {
	return <Panel />;
}
