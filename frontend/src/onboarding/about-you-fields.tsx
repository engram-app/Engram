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
	// The page heading IS the heard-from question, so that group borrows it
	// as its accessible name instead of repeating it in a legend.
	headingId: string;
}

// Optional user-voice questions on the about step. Nothing here gates
// Continue; answers go to POST /feedback (kind: onboarding).
function AboutYouFields({ value, onChange, headingId }: AboutYouFieldsProps) {
	const { t } = useT();

	function toggleGoal(slug: string) {
		const goals = value.goals.includes(slug)
			? value.goals.filter((s) => s !== slug)
			: [...value.goals, slug];
		onChange({ ...value, goals });
	}

	return (
		<>
			<HeardFromField
				heardFrom={value.heardFrom}
				detail={value.heardFromDetail}
				onChange={(heardFrom, heardFromDetail) =>
					onChange({ ...value, heardFrom, heardFromDetail })
				}
				labelledBy={headingId}
			/>

			<fieldset className="flex flex-col gap-2">
				<legend className={legend}>{t("What will you use Engram for?")}</legend>
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
		</>
	);
}

const legend = "mb-3 font-semibold text-base text-foreground";

interface HeardFromFieldProps {
	heardFrom: string | null;
	detail: string;
	onChange: (heardFrom: string | null, detail: string) => void;
	// The id of the visible question, used as the group's accessible name.
	labelledBy: string;
}

// "How did you hear about Engram?": on the terms screen for a web signup, and
// in the about-you survey.
function HeardFromField({ heardFrom, detail, onChange, labelledBy }: HeardFromFieldProps) {
	const { t } = useT();
	return (
		<fieldset aria-labelledby={labelledBy} className="flex flex-col gap-2">
			<RadioGroup
				value={heardFrom ?? ""}
				onValueChange={(next) => onChange(next, detail)}
				className="grid-cols-1 sm:grid-cols-2"
			>
				{HEARD_FROM.map((opt) => (
					<label key={opt.slug} className={selectableRow(heardFrom === opt.slug, true)}>
						<RadioGroupItem value={opt.slug} aria-label={t(opt.label)} />
						<span className="text-sm">{t(opt.label)}</span>
					</label>
				))}
			</RadioGroup>
			{heardFrom === "other" ? (
				<DetailInput value={detail} onChange={(next) => onChange(heardFrom, next)} />
			) : null}
		</fieldset>
	);
}

// The free-text follow-up shown under a question once its "Other" is picked.
function DetailInput({ value, onChange }: { value: string; onChange: (next: string) => void }) {
	const { t } = useT();
	return (
		<label className="mt-1 flex flex-col gap-1.5 text-sm">
			<span className="text-muted-foreground">{t("Tell us more")}</span>
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
export { AboutYouFields, aboutYouBody, EMPTY_ABOUT_YOU, HeardFromField };
