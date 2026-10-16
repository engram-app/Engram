import { HelpTip } from "@/components/help-tip";
import { Checkbox } from "@/components/ui/checkbox";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import type { UIText } from "@/i18n/ui-text";
import { selectableRow } from "@/lib/ui-classes";
import { NO_AI_TOOL, TOOL_ASSISTANTS, TOOL_CODING, type ToolOption } from "./onboarding-tools";
import { ToolBadge } from "./tool-icon";

interface ToolPickerProps {
	selected: Set<string>;
	onChange: (next: Set<string>) => void;
}

// "Which AI tools do you use?" as a controlled picker, asked in the in-app
// survey (survey-modal.tsx). Slugs mirror the backend `@valid_tools`.
function ToolPicker({ selected, onChange }: ToolPickerProps) {
	const { t } = useT();
	const tools = selected;

	function toggleTool(slug: string) {
		const next = new Set(tools);
		if (next.has(slug)) {
			next.delete(slug);
		} else {
			next.add(slug);
		}
		// Picking any client contradicts "I'm not connecting one".
		next.delete(NO_AI_TOOL.slug);
		onChange(next);
	}

	// Mutually exclusive with every client: selecting it clears the grid, so the
	// two answers can never both be true.
	function toggleNoAiTool() {
		onChange(tools.has(NO_AI_TOOL.slug) ? new Set() : new Set([NO_AI_TOOL.slug]));
	}

	return (
		<>
			<div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
				<ToolColumn
					title={t("AI assistants")}
					options={TOOL_ASSISTANTS}
					selected={tools}
					onToggle={toggleTool}
				/>
				<ToolColumn
					title={t("Coding tools")}
					options={TOOL_CODING}
					selected={tools}
					onToggle={toggleTool}
				/>
			</div>

			{/* The opt-out sits apart from the grid on purpose: it is the answer
		    "none", not another client, so it cannot sensibly coexist with a
		    selection. Own row, own separator, and picking it clears the rest. */}
			<label className="flex cursor-pointer items-center gap-3 rounded-lg border border-border bg-muted/30 p-3">
				<Checkbox
					checked={tools.has(NO_AI_TOOL.slug)}
					onCheckedChange={() => toggleNoAiTool()}
					aria-label={t(NO_AI_TOOL.label)}
				/>
				<span className="flex flex-col gap-0.5">
					<span className="font-medium text-foreground text-sm">{t(NO_AI_TOOL.label)}</span>
					<span className="text-muted-foreground text-xs">
						{NO_AI_TOOL.hint ? t(NO_AI_TOOL.hint) : null}
					</span>
				</span>
			</label>

			<p className="text-muted-foreground text-sm">
				<Trans
					text="Not a comprehensive list, pick {client} if yours isn't here."
					slots={{ client: <strong>{t("Another MCP client")}</strong> }}
				/>
			</p>
		</>
	);
}

interface ToolColumnProps {
	title: UIText;
	options: ToolOption[];
	selected: Set<string>;
	onToggle: (slug: string) => void;
}

function ToolColumn({ title, options, selected, onToggle }: ToolColumnProps) {
	const { t } = useT();
	const toolLabel = (opt: ToolOption) => (opt.translate ? t(opt.label) : opt.label);
	return (
		<fieldset className="flex flex-col gap-2">
			<legend className="mb-2 font-semibold text-muted-foreground text-xs uppercase tracking-wider">
				{title}
			</legend>
			<div className="flex flex-col gap-2">
				{options.map((opt) =>
					opt.unavailable ? (
						// Not a <label>: there is nothing to activate, and a label
						// implying clickability on an unselectable row is a worse lie
						// than the greying.
						//
						// Same padding/gap as selectableRow(_, true) so the row keeps the
						// grid rhythm, dashed border + muted content carry "unavailable"
						// instead of extra height. The reason moves into a HelpTip so it
						// stays reachable by keyboard and on touch; a hover tooltip would
						// be neither, since a disabled checkbox cannot take focus.
						<div
							key={opt.slug}
							aria-disabled
							className="flex items-center gap-3 rounded-lg border border-border border-dashed p-2.5"
						>
							<span className="flex items-center gap-3 opacity-60">
								<Checkbox checked={false} disabled aria-label={toolLabel(opt)} />
								<ToolBadge slug={opt.slug} fallbackLabel={toolLabel(opt)} />
							</span>
							{/* Full opacity: the affordance has to stay legible even though
							    the row it explains is greyed out. */}
							<HelpTip
								label={t("Why {tool} can't be connected", { tool: toolLabel(opt) })}
								className="ms-auto"
							>
								{t(opt.unavailable)}
							</HelpTip>
						</div>
					) : (
						<label key={opt.slug} className={selectableRow(selected.has(opt.slug), true)}>
							<Checkbox
								checked={selected.has(opt.slug)}
								onCheckedChange={() => onToggle(opt.slug)}
								aria-label={toolLabel(opt)}
							/>
							<ToolBadge slug={opt.slug} fallbackLabel={toolLabel(opt)} />
						</label>
					),
				)}
			</div>
		</fieldset>
	);
}

export { ToolPicker };
