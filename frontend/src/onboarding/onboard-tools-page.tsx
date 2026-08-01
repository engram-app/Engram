import { useState } from "react";
import { Link, Navigate, useNavigate } from "react-router";
import { HelpTip } from "@/components/help-tip";
import { Checkbox } from "@/components/ui/checkbox";
import AuthPanel from "@/layout/auth-panel";
import { heading, selectableRow } from "@/lib/ui-classes";
import { useOnboardingStatus, useSetOnboardingProfile } from "../api/queries";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import LoadingScreen from "../layout/loading-screen";
import { NO_AI_TOOL, TOOL_ASSISTANTS, TOOL_CODING, type ToolOption } from "./onboarding-tools";
import { ToolBadge } from "./tool-icon";

interface ToolsFormProps {
	initialTools: string[];
	isPending: boolean;
	hasError: boolean;
	isFree: boolean;
	onSubmit: (tools: string[]) => Promise<void>;
}

function ToolsForm({ initialTools, isPending, hasError, isFree, onSubmit }: ToolsFormProps) {
	// Free tier is single-select, if the user arrives with multiple already
	// saved, drop everything except the first so the UI invariant holds from
	// the first render.
	const [tools, setTools] = useState<Set<string>>(() => {
		if (isFree && initialTools.length > 1) {
			return new Set(initialTools.slice(0, 1));
		}
		return new Set(initialTools);
	});

	function toggleTool(slug: string) {
		setTools((prev) => {
			if (isFree) {
				// Free tier: clicking a selected tool deselects it; clicking any
				// other tool replaces the selection entirely.
				if (prev.has(slug)) {
					return new Set();
				}
				return new Set([slug]);
			}
			const next = new Set(prev);
			if (next.has(slug)) {
				next.delete(slug);
			} else {
				next.add(slug);
			}
			// Picking any client contradicts "I'm not connecting one".
			next.delete(NO_AI_TOOL.slug);
			return next;
		});
	}

	// Mutually exclusive with every client: selecting it clears the grid, so the
	// two answers can never both be true. Deselecting just empties the form,
	// which leaves Continue disabled until something is chosen.
	function toggleNoAiTool() {
		setTools((prev) => (prev.has(NO_AI_TOOL.slug) ? new Set() : new Set([NO_AI_TOOL.slug])));
	}

	async function submit() {
		if (tools.size === 0 || isPending) {
			return;
		}
		await onSubmit(Array.from(tools));
	}

	const canContinue = tools.size > 0 && !isPending;

	return (
		<AuthPanel className="flex flex-col gap-5">
			<header className="flex flex-col gap-2">
				<h1 className={heading}>Which AI tools do you use?</h1>
				<p className="text-base text-foreground">
					We'll tailor your setup around the tools you already work with.
				</p>
			</header>

			{isFree ? (
				<p className="rounded-md border border-border bg-muted/40 px-3 py-2 text-muted-foreground text-sm">
					Free tier, pick 1 to start.{" "}
					<Link
						to="/onboard/billing"
						className="font-medium text-foreground underline underline-offset-4"
					>
						Upgrade
					</Link>{" "}
					anytime for unlimited connections.
				</p>
			) : null}

			<div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
				<ToolColumn
					title="AI assistants"
					options={TOOL_ASSISTANTS}
					selected={tools}
					onToggle={toggleTool}
				/>
				<ToolColumn
					title="Coding tools"
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
					aria-label={NO_AI_TOOL.label}
				/>
				<span className="flex flex-col gap-0.5">
					<span className="font-medium text-foreground text-sm">{NO_AI_TOOL.label}</span>
					<span className="text-muted-foreground text-xs">{NO_AI_TOOL.hint}</span>
				</span>
			</label>

			<p className="text-muted-foreground text-sm">
				Not a comprehensive list, pick <strong>Another MCP client</strong> if yours isn't here.
			</p>

			{hasError ? (
				<p role="alert" className="text-destructive text-sm">
					Couldn't save your answers, please try again.
				</p>
			) : null}
			<div className="flex items-center justify-end">
				<button
					type="button"
					onClick={submit}
					disabled={!canContinue}
					className="rounded-lg bg-primary px-6 py-2 font-medium text-primary-foreground text-sm transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
				>
					{isPending ? "Saving…" : "Continue"}
				</button>
			</div>
		</AuthPanel>
	);
}

interface ToolColumnProps {
	title: string;
	options: ToolOption[];
	selected: Set<string>;
	onToggle: (slug: string) => void;
}

function ToolColumn({ title, options, selected, onToggle }: ToolColumnProps) {
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
								<Checkbox checked={false} disabled aria-label={opt.label} />
								<ToolBadge slug={opt.slug} fallbackLabel={opt.label} />
							</span>
							{/* Full opacity: the affordance has to stay legible even though
							    the row it explains is greyed out. */}
							<HelpTip label={`Why ${opt.label} can't be connected`} className="ms-auto">
								{opt.unavailable}
							</HelpTip>
						</div>
					) : (
						<label key={opt.slug} className={selectableRow(selected.has(opt.slug), true)}>
							<Checkbox
								checked={selected.has(opt.slug)}
								onCheckedChange={() => onToggle(opt.slug)}
								aria-label={opt.label}
							/>
							<ToolBadge slug={opt.slug} fallbackLabel={opt.label} />
						</label>
					),
				)}
			</div>
		</fieldset>
	);
}

export default function OnboardToolsPage() {
	const navigate = useNavigate();
	const { data: status, isLoading } = useOnboardingStatus();
	const setProfile = useSetOnboardingProfile();
	const isFree = useIsFreeTier();

	if (isLoading || !status) {
		return <LoadingScreen />;
	}

	// Honor backend ordering. Agreement/billing must come first; :done means
	// we shouldn't be in the wizard. :tools (own step) and :vault (re-edit
	// allowed for users who already picked tools and want to revise) both
	// render this page.
	if (status.next_step !== "tools" && status.next_step !== "vault" && status.next_step !== "done") {
		return <Navigate to={`/onboard/${status.next_step}`} replace />;
	}
	if (status.next_step === "done") {
		return <Navigate to="/" replace />;
	}

	return (
		<ToolsForm
			initialTools={status.profile?.tools ?? []}
			isPending={setProfile.isPending}
			hasError={setProfile.isError}
			isFree={isFree}
			onSubmit={async (tools) => {
				await setProfile.mutateAsync({ tools });
				navigate("/onboard/vault", { replace: true });
			}}
		/>
	);
}
