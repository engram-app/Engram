import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { HEARD_FROM, USE_CASES } from "@/feedback/options";
import { useT } from "@/i18n/locale-provider";
import { selectableRow } from "@/lib/ui-classes";

interface UseCasesFieldProps {
	goals: string[];
	detail: string;
	onChange: (goals: string[], detail: string) => void;
}

// "What will you use Engram for?", asked in the in-app survey.
function UseCasesField({ goals, detail, onChange }: UseCasesFieldProps) {
	const { t } = useT();

	function toggleGoal(slug: string) {
		const next = goals.includes(slug) ? goals.filter((s) => s !== slug) : [...goals, slug];
		onChange(next, detail);
	}

	return (
		<fieldset className="flex flex-col gap-2">
			<legend className={legend}>{t("What will you use Engram for?")}</legend>
			<div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
				{USE_CASES.map((opt) => (
					<label key={opt.slug} className={selectableRow(goals.includes(opt.slug), true)}>
						<Checkbox
							checked={goals.includes(opt.slug)}
							onCheckedChange={() => toggleGoal(opt.slug)}
							aria-label={t(opt.label)}
						/>
						<span className="text-sm">{t(opt.label)}</span>
					</label>
				))}
			</div>
			{goals.includes("other") ? (
				<DetailInput value={detail} onChange={(next) => onChange(goals, next)} />
			) : null}
		</fieldset>
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

// "How did you hear about Engram?": a web signup's own wizard step
// (heard-page.tsx).
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

export { HeardFromField, UseCasesField };
