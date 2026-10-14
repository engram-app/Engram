import { Link } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import type { LegalNotice } from "../api/queries";
import { useOnboardingStatus } from "../api/queries";
import { useAcceptCurrentAgreements } from "./use-accept-current";

export function formatEffectiveDate(isoDate: string, locale: string): string {
	return new Intl.DateTimeFormat(locale, { dateStyle: "long", timeZone: "UTC" }).format(
		new Date(`${isoDate}T00:00:00Z`),
	);
}

export function useDocumentName() {
	const { t } = useT();
	return (notice: LegalNotice) =>
		notice.document === "terms_of_service" ? t("Terms of Service") : t("Privacy Policy");
}

// Pending legal changes, until the user accepts or the change takes effect.
// A notice-only change can be dismissed (that records acceptance of the
// current versions, so it stays dismissed on every device). A material change
// can only be reviewed and accepted.
export function LegalNoticeBanner() {
	const { t, renderedLocale } = useT();
	const name = useDocumentName();
	const { data } = useOnboardingStatus();
	const { accept, isPending, ready } = useAcceptCurrentAgreements();
	const notices = data?.legal_notices ?? [];
	if (notices.length === 0) {
		return null;
	}
	const material = notices.some((n) => n.material);

	return (
		<aside
			role="status"
			className="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 bg-sky-50 px-4 py-2 text-sky-950 text-sm dark:bg-sky-950/40 dark:text-sky-100"
		>
			<ul>
				{notices.map((n) => (
					<li key={n.document}>
						{t("{document} update, effective {date}.", {
							document: name(n),
							date: formatEffectiveDate(n.effective_date, renderedLocale),
						})}{" "}
						{n.changelog}{" "}
						<a
							href={n.url}
							target="_blank"
							rel="noreferrer noopener"
							className="font-medium underline underline-offset-4"
						>
							{t("Read it")}
						</a>
					</li>
				))}
			</ul>
			{material ? (
				<Link to="/onboard/agreement" className="font-medium underline underline-offset-4">
					{t("Review and accept")}
				</Link>
			) : (
				<Button
					type="button"
					size="sm"
					variant="outline"
					disabled={!ready || isPending}
					// The banner stays up on failure, so the user can retry.
					onClick={() => accept().catch(console.error)}
				>
					{t("Got it")}
				</Button>
			)}
		</aside>
	);
}
