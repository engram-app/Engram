import { useState } from "react";
import { Link, Navigate, useNavigate } from "react-router";
import { Checkbox } from "@/components/ui/checkbox";
import AuthPanel from "@/layout/auth-panel";
import { heading, selectableRow } from "@/lib/ui-classes";
import { useOnboardingStatus, useSetOnboardingProfile } from "../api/queries";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import LoadingScreen from "../layout/loading-screen";
import { TOOL_ASSISTANTS, TOOL_CODING, TOOL_OTHER, type ToolOption } from "./onboarding-tools";
import { ToolBadge } from "./tool-icon";

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

interface ToolsFormProps {
	initialTools: string[];
	isPending: boolean;
	hasError: boolean;
	isFree: boolean;
	onSubmit: (tools: string[]) => Promise<void>;
}

function ToolsForm({ initialTools, isPending, hasError, isFree, onSubmit }: ToolsFormProps) {
	// Free tier is single-select — if the user arrives with multiple already
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
			next.has(slug) ? next.delete(slug) : next.add(slug);
			return next;
		});
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
					Free tier — pick 1 to start.{" "}
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

			<ToolColumn
				title="Other connections"
				options={TOOL_OTHER}
				selected={tools}
				onToggle={toggleTool}
				layout="row"
			/>

			<p className="text-muted-foreground text-sm">
				Not a comprehensive list — pick <strong>Other connection</strong> if yours isn't here.
			</p>

			{hasError ? (
				<p role="alert" className="text-destructive text-sm">
					Couldn't save your answers — please try again.
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
	layout?: "stack" | "row";
}

function ToolColumn({ title, options, selected, onToggle, layout = "stack" }: ToolColumnProps) {
	const innerClass =
		layout === "row" ? "grid grid-cols-1 gap-2 sm:grid-cols-2" : "flex flex-col gap-2";

	return (
		<fieldset className="flex flex-col gap-2">
			<legend className="mb-2 font-semibold text-muted-foreground text-xs uppercase tracking-wider">
				{title}
			</legend>
			<div className={innerClass}>
				{options.map((opt) => (
					<label key={opt.slug} className={selectableRow(selected.has(opt.slug), true)}>
						<Checkbox
							checked={selected.has(opt.slug)}
							onCheckedChange={() => onToggle(opt.slug)}
							aria-label={opt.label}
						/>
						<ToolBadge slug={opt.slug} fallbackLabel={opt.label} />
					</label>
				))}
			</div>
		</fieldset>
	);
}
