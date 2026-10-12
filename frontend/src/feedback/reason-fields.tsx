import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Textarea } from "@/components/ui/textarea";
import { useT } from "@/i18n/locale-provider";
import { selectableRow } from "@/lib/ui-classes";
import { CANCEL_REASONS } from "./options";

interface ReasonFieldsProps {
	legend: string;
	value: Reason;
	onChange: (value: Reason) => void;
}

export interface Reason {
	reason: string | null;
	detail: string;
}

export const EMPTY_REASON: Reason = { reason: null, detail: "" };

// A reason AND a sentence: the cancel flow requires both. Account deletion
// does not, since erasure must never be gated on giving feedback.
export function reasonComplete(answer: Reason): answer is Reason & { reason: string } {
	return answer.reason !== null && answer.detail.trim() !== "";
}

// Shared by the subscription cancel panel and account deletion.
export function ReasonFields({ legend, value, onChange }: ReasonFieldsProps) {
	const { t } = useT();
	return (
		<>
			<fieldset className="flex flex-col gap-2">
				<legend className="mb-2 font-medium text-foreground text-sm">{legend}</legend>
				<RadioGroup
					value={value.reason ?? ""}
					onValueChange={(reason) => onChange({ ...value, reason })}
					className="sm:grid-cols-2"
				>
					{CANCEL_REASONS.map((opt) => (
						<label key={opt.slug} className={selectableRow(value.reason === opt.slug, true)}>
							<RadioGroupItem value={opt.slug} aria-label={t(opt.label)} />
							<span className="text-sm">{t(opt.label)}</span>
						</label>
					))}
				</RadioGroup>
			</fieldset>
			<label className="flex flex-col gap-1.5 text-sm">
				<span className="font-medium text-foreground">{t("Tell us more")}</span>
				<Textarea
					value={value.detail}
					maxLength={2000}
					onChange={(e) => onChange({ ...value, detail: e.target.value })}
				/>
			</label>
		</>
	);
}
