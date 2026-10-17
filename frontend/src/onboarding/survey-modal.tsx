import { useState } from "react";
import { useLocation } from "react-router";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useConfig } from "@/config-context";
import { useT } from "@/i18n/locale-provider";
import { isSettingsHash } from "@/settings/settings-hash";
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
	const { hash } = useLocation();
	const { has } = useOnboardingActions();
	const [closed, setClosed] = useState(false);
	// Only an account that may still be asked pays for these reads.
	const eligible =
		billingEnabled && status?.next_step === "done" && surveyPending(status.profile) && !closed;
	const { data: vaults } = useVaults({ enabled: eligible });
	const { data: connections } = useConnections({ enabled: eligible });

	// First value: a live connection to an AI tool or the plugin, the plugin
	// ever linked, or notes beyond the welcome note. Not an API key (creating
	// one would open this over a key shown only once), and not the
	// `ai_connected` action: nothing records it.
	const gotValue =
		(connections ?? []).some((c) => c.kind !== "pat") ||
		has("plugin_connected") ||
		(vaults ?? []).some((v) => v.populated);
	// Held back while another surface owns the screen: the first-vault modal
	// (`suppressed`) or the Settings overlay.
	const due = eligible && gotValue && !suppressed && !isSettingsHash(hash);

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
				// Mid-save, a skip would race the answers with an empty one.
				if (!(open || pending)) {
					skip();
				}
			}}
		>
			<DialogContent className="flex max-h-[90dvh] flex-col sm:max-w-2xl">
				<DialogHeader>
					<DialogTitle>{t("Help us shape Engram")}</DialogTitle>
					<DialogDescription>{t("Two quick questions. Both are optional.")}</DialogDescription>
				</DialogHeader>

				{/* Only the questions scroll: the tool grid is tall enough to push
				    the buttons below the fold, and the way out must stay in view. */}
				<ScrollArea
					// Flex all the way down: the dialog only has a max height, so a
					// percentage height on the viewport would resolve to auto and
					// never scroll. Shrinking as flex items does.
					className="-mx-6 flex min-h-0 flex-1 flex-col"
					viewportClassName="h-auto min-h-0 flex-1 px-6"
				>
					<section className="mb-4 flex flex-col gap-3">
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
						<p role="alert" className="mt-4 text-destructive text-sm">
							{t("Couldn't save your answers, please try again.")}
						</p>
					) : null}
				</ScrollArea>

				<DialogFooter className="-mx-6 -mb-6 border-border border-t p-6 pt-3">
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
