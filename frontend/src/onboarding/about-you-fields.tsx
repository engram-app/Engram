import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { HEARD_FROM, USE_CASES } from "@/feedback/options";
import { useT } from "@/i18n/locale-provider";
import { selectableRow } from "@/lib/ui-classes";

interface AboutYou {
	heardFrom: string | null;
	goals: string[];
	goalsDetail: string;
	heardFromDetail: string;
}

interface AboutYouFieldsProps {
	value: AboutYou;
	onChange: (next: AboutYou) => void;
}

// Optional "about you" questions on the tools step. Nothing here gates
// Continue; answers go to POST /feedback (kind: onboarding).
function AboutYouFields({ value, onChange }: AboutYouFieldsProps) {
	const { t } = useT();

	function toggleGoal(slug: string) {
		const goals = value.goals.includes(slug)
			? value.goals.filter((s) => s !== slug)
			: [...value.goals, slug];
		onChange({ ...value, goals });
	}

	return (
		<>
			<fieldset className="flex flex-col gap-2">
				<legend className={legend}>{t("What will you use Engram for? (optional)")}</legend>
				<div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
					{USE_CASES.map((opt) => (
						<label key={opt.slug} className={selectableRow(value.goals.includes(opt.slug), true)}>
							<Checkbox
								checked={value.goals.includes(opt.slug)}
								onCheckedChange={() => toggleGoal(opt.slug)}
								aria-label={t(opt.label)}
							/>
							<span className="text-sm">{t(opt.label)}</span>
						</label>
					))}
				</div>
				{value.goals.includes("other") ? (
					<DetailInput
						value={value.goalsDetail}
						onChange={(goalsDetail) => onChange({ ...value, goalsDetail })}
					/>
				) : null}
			</fieldset>

			<fieldset className="flex flex-col gap-2">
				<legend className={legend}>{t("How did you hear about Engram? (optional)")}</legend>
				<RadioGroup
					value={value.heardFrom ?? ""}
					onValueChange={(heardFrom) => onChange({ ...value, heardFrom })}
					className="grid-cols-1 sm:grid-cols-2"
				>
					{HEARD_FROM.map((opt) => (
						<label key={opt.slug} className={selectableRow(value.heardFrom === opt.slug, true)}>
							<RadioGroupItem value={opt.slug} aria-label={t(opt.label)} />
							<span className="text-sm">{t(opt.label)}</span>
						</label>
					))}
				</RadioGroup>
				{value.heardFrom === "other" ? (
					<DetailInput
						value={value.heardFromDetail}
						onChange={(heardFromDetail) => onChange({ ...value, heardFromDetail })}
					/>
				) : null}
			</fieldset>
		</>
	);
}

const legend = "mb-3 font-semibold text-base text-foreground";

// The free-text follow-up shown under a question once its "Other" is picked.
function DetailInput({ value, onChange }: { value: string; onChange: (next: string) => void }) {
	const { t } = useT();
	return (
		<label className="mt-1 flex flex-col gap-1.5 text-sm">
			<span className="text-muted-foreground">{t("Tell us more (optional)")}</span>
			<Input value={value} maxLength={2000} onChange={(e) => onChange(e.target.value)} />
		</label>
	);
}

const EMPTY_ABOUT_YOU: AboutYou = {
	heardFrom: null,
	goals: [],
	goalsDetail: "",
	heardFromDetail: "",
};

// The POST body for these answers, or null when the user skipped them all.
function aboutYouBody(value: AboutYou) {
	if (value.heardFrom === null && value.goals.length === 0) {
		return null;
	}
	// A follow-up only counts while its "Other" is still picked.
	const goalsDetail = value.goals.includes("other") ? value.goalsDetail.trim() : "";
	const heardFromDetail = value.heardFrom === "other" ? value.heardFromDetail.trim() : "";
	return {
		kind: "onboarding" as const,
		...(value.heardFrom ? { heard_from: value.heardFrom } : {}),
		...(value.goals.length > 0 ? { use_cases: value.goals } : {}),
		...(goalsDetail ? { use_cases_detail: goalsDetail } : {}),
		...(heardFromDetail ? { heard_from_detail: heardFromDetail } : {}),
	};
}

export type { AboutYou };
export { AboutYouFields, aboutYouBody, EMPTY_ABOUT_YOU };
