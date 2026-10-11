import { useId, useState } from "react";
import { Navigate, useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import AuthPanel from "@/layout/auth-panel";
import { heading } from "@/lib/ui-classes";
import { track } from "../analytics/track";
import { useOnboardingStatus, useSubmitFeedback } from "../api/queries";
import LoadingScreen from "../layout/loading-screen";
import { type AboutYou, AboutYouFields, aboutYouBody, EMPTY_ABOUT_YOU } from "./about-you-fields";
import { onboardingDoneTarget } from "./onboarding-next";

// Optional user-voice step (hosted only). Answering or skipping both POST
// /feedback, which stamps survey_done_at and lets the wizard move on to :vault.
export default function OnboardAboutPage() {
	const { t } = useT();
	const navigate = useNavigate();
	const { data: status, isLoading } = useOnboardingStatus();
	const submitFeedback = useSubmitFeedback();
	const [aboutYou, setAboutYou] = useState<AboutYou>(EMPTY_ABOUT_YOU);
	const [mountedAt] = useState(() => Date.now());
	const headingId = useId();

	if (isLoading || !status) {
		return <LoadingScreen />;
	}
	// :vault is allowed so Back from the vault step can revise the answers.
	if (status.next_step === "done") {
		return <Navigate to={onboardingDoneTarget()} replace />;
	}
	if (status.next_step !== "about" && status.next_step !== "vault") {
		return <Navigate to={`/onboard/${status.next_step}`} replace />;
	}

	async function finish(skipped: boolean) {
		const body = skipped ? null : aboutYouBody(aboutYou);
		try {
			await submitFeedback.mutateAsync(body ?? { kind: "onboarding" });
		} catch {
			// isError renders the alert; stay on the step so they can retry.
			return;
		}
		track("onboarding_step_completed", { step: "about", duration_ms: Date.now() - mountedAt });
		navigate("/onboard/vault", { replace: true });
	}

	return (
		<AuthPanel className="flex flex-col gap-5">
			<h1 id={headingId} className={heading}>
				{t("How did you hear about Engram?")}
			</h1>

			<AboutYouFields value={aboutYou} onChange={setAboutYou} headingId={headingId} />

			{submitFeedback.isError ? (
				<p role="alert" className="text-destructive text-sm">
					{t("Couldn't save your answers, please try again.")}
				</p>
			) : null}
			<footer className="flex items-center justify-end gap-2">
				<Button
					type="button"
					variant="ghost"
					onClick={() => finish(true)}
					disabled={submitFeedback.isPending}
				>
					{t("Skip")}
				</Button>
				<Button type="button" onClick={() => finish(false)} disabled={submitFeedback.isPending}>
					{submitFeedback.isPending ? t("Saving…") : t("Continue")}
				</Button>
			</footer>
		</AuthPanel>
	);
}
