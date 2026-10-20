import { useState } from "react";
import { useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import AuthPanel from "@/layout/auth-panel";
import { destructiveAlert, heading, selectableRow } from "@/lib/ui-classes";
import { track } from "../analytics/track";
import { useOnboardingStatus } from "../api/queries";
import { LegalDoc } from "../legal/legal-doc";
import { formatEffectiveDate, useDocumentName } from "../legal/legal-notice-banner";
import { useAcceptAgreements } from "../legal/use-accept-current";

// The legal texts take whatever height the card has left, so the agreement
// and Continue stay on screen without the page scrolling (AuthPanel).
const fillRest = "flex min-h-32 flex-1 flex-col rounded-lg border border-border bg-background";
const fillRestViewport = "h-auto min-h-0 flex-1";

export default function AgreementPage() {
	const { t, renderedLocale } = useT();
	const name = useDocumentName();
	const [agreed, setAgreed] = useState(false);
	const navigate = useNavigate();
	const { data } = useOnboardingStatus();
	const { accept, isPending, ready, unavailable, tosText, privacyText } = useAcceptAgreements();
	const [showPrivacy, setShowPrivacy] = useState(false);
	const [mountedAt] = useState(() => Date.now());
	const notices = data?.legal_notices ?? [];
	// Guards a second accept while the first is still in flight.
	const [submitting, setSubmitting] = useState(false);
	const [failed, setFailed] = useState(false);

	async function submit() {
		if (submitting) {
			return;
		}
		setSubmitting(true);
		setFailed(false);
		try {
			await submitSteps();
		} catch {
			// A dropped request (Safari's "Load failed") or a 5xx: the accept
			// did not land, so say so and leave Continue live to retry. The api
			// client has already reported the failure.
			setFailed(true);
		} finally {
			setSubmitting(false);
		}
	}

	async function submitSteps() {
		if (!(await accept())) {
			return;
		}
		track("onboarding_step_completed", {
			step: "agreement",
			duration_ms: Date.now() - mountedAt,
		});
		navigate("/onboard", { replace: true });
	}

	return (
		<AuthPanel scroll={false} className="gap-4">
			<h1 className={heading}>{t("Review the Terms")}</h1>
			<p className="text-muted-foreground text-sm">
				<Trans
					text="Please read the full agreement below before continuing. Our {privacy} (reviewed at signup) describes how we handle your data."
					slots={{
						// The exact version being accepted, in-app: the public page
						// is unversioned and can differ from the hash recorded.
						privacy: (
							<button
								type="button"
								aria-expanded={showPrivacy}
								aria-controls="privacy-notice"
								onClick={() => setShowPrivacy((v) => !v)}
								className="font-medium text-primary-ink underline-offset-4 hover:underline"
							>
								{t("privacy notice")}
							</button>
						),
					}}
				/>
			</p>
			{notices.length > 0 ? (
				<section
					aria-labelledby="what-changed"
					className="rounded-lg border border-border p-4 text-sm"
				>
					<h2 id="what-changed" className="font-medium text-foreground">
						{t("What changed")}
					</h2>
					<ul className="mt-2 flex flex-col gap-2 text-muted-foreground">
						{notices.map((n) => (
							<li key={n.document}>
								<span className="font-medium text-foreground">
									{t("{document}, effective {date}:", {
										document: name(n),
										date: formatEffectiveDate(n.effective_date, renderedLocale),
									})}
								</span>{" "}
								{n.changelog}{" "}
								<a
									href={n.url}
									target="_blank"
									rel="noreferrer noopener"
									className="font-medium text-primary underline-offset-4 hover:underline"
								>
									{t("Read it")}
								</a>
							</li>
						))}
					</ul>
				</section>
			) : null}
			{unavailable ? (
				<div role="alert" className={destructiveAlert}>
					<p className="font-medium text-foreground">
						{t("The current agreement isn’t available right now.")}
					</p>
					<p className="mt-1 text-muted-foreground">
						{t(
							"We can’t display the latest terms at the moment, so signup is paused rather than asking you to agree to something you can’t read. Please try again shortly.",
						)}
					</p>
				</div>
			) : (
				<>
					{tosText ? (
						// One box for both texts: two boxes each needing a minimum height
						// pushed Continue off a short screen.
						<ScrollArea className={fillRest} viewportClassName={fillRestViewport}>
							{showPrivacy && privacyText ? (
								<article id="privacy-notice" className="border-border border-b p-4">
									<LegalDoc source={privacyText} />
								</article>
							) : null}
							<article className="p-4">
								<LegalDoc source={tosText} />
							</article>
						</ScrollArea>
					) : null}
					<label className={selectableRow(agreed)}>
						<Checkbox
							checked={agreed}
							onCheckedChange={(v) => setAgreed(v === true)}
							aria-label={t("I have read and agree to the Terms of Service and Privacy Policy")}
						/>
						<span className="font-medium text-foreground text-sm">
							{t("I have read and agree to the agreement shown above and the privacy notice")}
						</span>
					</label>
					{failed ? (
						<p role="alert" className={destructiveAlert}>
							{t("Could not continue. Please try again.")}
						</p>
					) : null}
					<Button
						type="button"
						onClick={submit}
						disabled={!agreed || isPending || submitting || !ready}
						className="w-full"
					>
						{isPending || submitting ? t("Saving…") : t("Continue")}
					</Button>
				</>
			)}
		</AuthPanel>
	);
}
