import { useId, useState } from "react";
import { useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import AuthPanel from "@/layout/auth-panel";
import { destructiveAlert, heading, selectableRow } from "@/lib/ui-classes";
import { track } from "../analytics/track";
import { useOnboardingStatus, useSubmitFeedback } from "../api/queries";
import { LegalDoc } from "../legal/legal-doc";
import { formatEffectiveDate, useDocumentName } from "../legal/legal-notice-banner";
import { useAcceptAgreements } from "../legal/use-accept-current";
import { HeardFromField } from "./about-you-fields";

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
	const submitFeedback = useSubmitFeedback();
	const [heardFrom, setHeardFrom] = useState<string | null>(null);
	const [heardFromDetail, setHeardFromDetail] = useState("");
	const heardFromId = useId();
	// Only a brand-new web signup is asked. Plugin and connector signups
	// record where they started instead, and a returning account re-accepting
	// changed terms already went through the wizard.
	const profile = data?.profile;
	const askHeardFrom = !(
		profile?.tools_prefilled ||
		profile?.signup_source ||
		profile?.completed_at ||
		profile?.survey_done_at ||
		profile?.heard_from
	);

	async function submit() {
		if (!(await accept())) {
			return;
		}
		if (askHeardFrom && heardFrom) {
			const detail = heardFrom === "other" ? heardFromDetail.trim() : "";
			// The terms are already accepted; a lost answer must not strand the
			// signup on this screen.
			await submitFeedback
				.mutateAsync({
					kind: "onboarding",
					heard_from: heardFrom,
					...(detail ? { heard_from_detail: detail } : {}),
				})
				.catch((err: unknown) => console.warn("heard_from submit failed", err));
		}
		track("onboarding_step_completed", {
			step: "agreement",
			duration_ms: Date.now() - mountedAt,
		});
		navigate("/onboard", { replace: true });
	}

	return (
		<AuthPanel className="flex flex-col gap-4">
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
			{showPrivacy && privacyText ? (
				<ScrollArea
					id="privacy-notice"
					className="h-[44dvh] rounded-lg border border-border bg-background sm:h-80"
				>
					<div className="p-4">
						<LegalDoc source={privacyText} />
					</div>
				</ScrollArea>
			) : null}
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
						<ScrollArea className="h-[44dvh] rounded-lg border border-border bg-background sm:h-80 lg:h-[60vh]">
							<div className="p-4">
								<LegalDoc source={tosText} />
							</div>
						</ScrollArea>
					) : null}
					{askHeardFrom ? (
						<section className="flex flex-col gap-3">
							<h2 id={heardFromId} className="font-semibold text-base text-foreground">
								{t("How did you hear about Engram?")}
							</h2>
							<HeardFromField
								heardFrom={heardFrom}
								detail={heardFromDetail}
								onChange={(next, detail) => {
									setHeardFrom(next);
									setHeardFromDetail(detail);
								}}
								labelledBy={heardFromId}
							/>
						</section>
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
					<Button
						type="button"
						onClick={submit}
						disabled={!agreed || isPending || !ready || (askHeardFrom && !heardFrom)}
						className="w-full"
					>
						{isPending ? t("Saving…") : t("Continue")}
					</Button>
				</>
			)}
		</AuthPanel>
	);
}
