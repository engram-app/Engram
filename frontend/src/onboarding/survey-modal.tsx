import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { useConfig } from "@/config-context";
import { useT } from "@/i18n/locale-provider";
import {
	type OnboardingProfile,
	useConnections,
	useOnboardingStatus,
	useSubmitFeedback,
	useVaults,
} from "../api/queries";
import { UseCasesField } from "./about-you-fields";
import { ToolPicker } from "./tool-picker";
import { useOnboardingActions } from "./use-onboarding-actions";

// The two questions that used to be wizard steps (tools, use cases), asked in
// the app once the account has got something out of Engram rather than before.
// Asking before value is where people drop off.

/** Not yet asked, and not answered in the old wizard. */
function surveyPending(profile: OnboardingProfile | undefined): boolean {
	const p = profile ?? {};
	// The old wizard asked both: a self-answered `tools` means it already ran.
	const answeredInWizard = Boolean(p.tools?.length && !p.tools_prefilled);
	return !(p.use_cases_done_at || p.use_cases?.length || answeredInWizard);
}

/** Renders the survey once it is due. Hosted only: self-host has no PostHog. */
function SurveyPrompt({ suppressed }: { suppressed: boolean }) {
	const { billingEnabled } = useConfig();
	const { data: status } = useOnboardingStatus();
	const { data: vaults } = useVaults();
	const { data: connections } = useConnections();
	const { has } = useOnboardingActions();
	const [closed, setClosed] = useState(false);

	// First value: a live connection (an AI tool or the plugin), the plugin
	// ever linked, or notes beyond the welcome note. Not the `ai_connected`
	// action: nothing records it.
	const gotValue =
		(connections ?? []).length > 0 ||
		has("plugin_connected") ||
		(vaults ?? []).some((v) => v.populated);
	const due =
		billingEnabled &&
		status?.next_step === "done" &&
		surveyPending(status.profile) &&
		gotValue &&
		!suppressed &&
		!closed;

	if (!(due && status)) {
		return null;
	}
	return <SurveyModal initialTools={status.profile?.tools ?? []} onDone={() => setClosed(true)} />;
}

interface SurveyModalProps {
	initialTools: string[];
	onDone: () => void;
}

function SurveyModal({ initialTools, onDone }: SurveyModalProps) {
	const { t } = useT();
	const submitFeedback = useSubmitFeedback();
	const [tools, setTools] = useState<Set<string>>(() => new Set(initialTools));
	const [goals, setGoals] = useState<string[]>([]);
	const [goalsDetail, setGoalsDetail] = useState("");
	const [failed, setFailed] = useState(false);
	const pending = submitFeedback.isPending;

	async function save() {
		const detail = goals.includes("other") ? goalsDetail.trim() : "";
		// ONE request: two would let the first flip the survey to answered and
		// unmount this modal before the second could report a failure. Always
		// carries `use_cases` (empty when none picked), which stamps the survey
		// as asked (`use_cases_done_at`).
		try {
			await submitFeedback.mutateAsync({
				kind: "onboarding",
				use_cases: goals,
				...(detail ? { use_cases_detail: detail } : {}),
				...(tools.size > 0 ? { tools: Array.from(tools) } : {}),
			});
		} catch {
			setFailed(true);
			return;
		}
		onDone();
	}

	// Closing is a skip, not a "later": the survey is never forced. A failed
	// skip just means it can come back next visit.
	function skip() {
		submitFeedback
			.mutateAsync({ kind: "onboarding", use_cases: [] })
			.catch((err: unknown) => console.warn("survey skip failed", err));
		onDone();
	}

	return (
		<Dialog
			open
			onOpenChange={(open) => {
				if (!open) {
					skip();
				}
			}}
		>
			<DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-2xl">
				<DialogHeader>
					<DialogTitle>{t("Help us shape Engram")}</DialogTitle>
					<DialogDescription>{t("Two quick questions. Both are optional.")}</DialogDescription>
				</DialogHeader>

				<section className="flex flex-col gap-3">
					<h3 className="font-semibold text-base text-foreground">
						{t("Which AI tools do you use?")}
					</h3>
					<ToolPicker selected={tools} onChange={setTools} />
				</section>

				<UseCasesField
					goals={goals}
					detail={goalsDetail}
					onChange={(next, detail) => {
						setGoals(next);
						setGoalsDetail(detail);
					}}
				/>

				{failed ? (
					<p role="alert" className="text-destructive text-sm">
						{t("Couldn't save your answers, please try again.")}
					</p>
				) : null}

				{/* Pinned: the tool grid is tall enough to push the buttons below
				    the fold, and the way out must always be in view. */}
				<DialogFooter className="sticky -bottom-6 -mx-6 -mb-6 border-border border-t bg-background p-6 pt-3">
					<Button type="button" variant="ghost" onClick={skip} disabled={pending}>
						{t("Skip")}
					</Button>
					<Button type="button" onClick={save} disabled={pending}>
						{pending ? t("Saving…") : t("Save")}
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}

export { SurveyModal, SurveyPrompt, surveyPending };
