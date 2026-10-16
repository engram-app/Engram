import { type SubmitEvent, useId, useState } from "react";
import { useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import AuthPanel from "@/layout/auth-panel";
import { destructiveAlert, heading } from "@/lib/ui-classes";
import { track } from "../analytics/track";
import { useSubmitFeedback } from "../api/queries";
import { HeardFromField } from "./about-you-fields";

// "How did you hear about Engram?", a web signup's step after the terms.
// Plugin and connector signups never reach it: where they started is the
// answer (`Onboarding.heard_due?/3`).
export default function HeardPage() {
	const { t } = useT();
	const navigate = useNavigate();
	const submitFeedback = useSubmitFeedback();
	const [heardFrom, setHeardFrom] = useState<string | null>(null);
	const [detail, setDetail] = useState("");
	const [saving, setSaving] = useState(false);
	const [failed, setFailed] = useState(false);
	const [mountedAt] = useState(() => Date.now());
	const headingId = useId();

	async function submit(event: SubmitEvent<HTMLFormElement>) {
		event.preventDefault();
		if (!heardFrom || saving) {
			return;
		}
		setSaving(true);
		setFailed(false);
		const trimmed = heardFrom === "other" ? detail.trim() : "";
		try {
			await submitFeedback.mutateAsync({
				kind: "onboarding",
				heard_from: heardFrom,
				...(trimmed ? { heard_from_detail: trimmed } : {}),
			});
		} catch {
			// The wizard stays on this step until the answer is saved, so
			// moving on would land right back here.
			setFailed(true);
			setSaving(false);
			return;
		}
		track("onboarding_step_completed", { step: "heard", duration_ms: Date.now() - mountedAt });
		navigate("/onboard", { replace: true });
	}

	return (
		<AuthPanel>
			<form onSubmit={submit} aria-labelledby={headingId} className="flex flex-col gap-4">
				<h1 id={headingId} className={heading}>
					{t("How did you hear about Engram?")}
				</h1>
				{heardFrom ? null : (
					<p className="text-muted-foreground text-sm">{t("Pick one to continue.")}</p>
				)}
				<HeardFromField
					heardFrom={heardFrom}
					detail={detail}
					onChange={(next, nextDetail) => {
						setHeardFrom(next);
						setDetail(nextDetail);
					}}
					labelledBy={headingId}
				/>
				{failed ? (
					<p role="alert" className={destructiveAlert}>
						{t("Couldn't save your answers, please try again.")}
					</p>
				) : null}
				<Button type="submit" disabled={!heardFrom || saving} className="w-full">
					{saving ? t("Saving…") : t("Continue")}
				</Button>
			</form>
		</AuthPanel>
	);
}
