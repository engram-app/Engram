import { type ReactNode, type RefObject, useEffect, useId, useRef, useState } from "react";
import { capLevel } from "@/components/access-level-select";
import { AccessSummary } from "@/components/access-summary";
import { Button } from "@/components/ui/button";
import { type VaultAccess, VaultAccessFields } from "@/components/vault-access-fields";
import { useT } from "@/i18n/locale-provider";
import type { UIText } from "@/i18n/ui-text";

interface FlowVault {
	id: string;
	name: string;
	is_default?: boolean;
	note_count?: number;
	attachment_count?: number;
}

// Pick vault access, then confirm a plain-language summary of it. One flow for
// OAuth consent and the New API Key dialog; the caller owns the access state
// (so it survives Back) and the request it turns into.
//
// Rendered as items of the caller's flex column: the pick step is a fragment,
// so the vault list stays a direct flex item and is the only part that
// shrinks, then scrolls (AuthPanel `scroll={false}`, the key dialog).
export function VaultAccessFlow({
	access,
	vaults,
	legend,
	name,
	fields,
	leveled = true,
	lockReadOnly = false,
	picker = true,
	ready = true,
	confirmLabel,
	pendingLabel,
	pending,
	onConfirm,
	onCancel,
	error,
	backFocus,
	settingsHint = true,
}: {
	access: VaultAccess;
	vaults: FlowVault[];
	legend: UIText;
	// Who the summary is about: "{name} will be able to:".
	name: string;
	// Pick-step fields above the picker (a connection or key name).
	fields?: ReactNode;
	// Per-vault levels; without them one box per row and no later-vaults policy.
	leveled?: boolean;
	// Drop Write everywhere (a client that asked for `mcp:read`).
	lockReadOnly?: boolean;
	// Show the picker at all (a backend without levels offers none).
	picker?: boolean;
	// The caller's own gate on Review (a required name).
	ready?: boolean;
	confirmLabel: UIText;
	pendingLabel: UIText;
	pending: boolean;
	onConfirm: () => void;
	// Absent: no Cancel (the consent page offers none on an unverified redirect).
	onCancel?: () => void;
	// Shown on the review step, where the confirm can fail.
	error?: ReactNode;
	// Focus target when Back returns to the pick step.
	backFocus?: RefObject<HTMLElement | null>;
	// Points to Settings > Connections; off when already there (editing).
	settingsHint?: boolean;
}) {
	const { t } = useT();
	const ids = vaults.map((v) => String(v.id));
	// The backend refuses a grant that reaches no vault, so it is never offered.
	const reachesNothing = !access.reaches(ids);
	// No Write anywhere caps every level at read.
	const maxLevel = lockReadOnly || !access.writes(ids) ? "read" : "write";
	const reasonId = useId();
	const headingId = useId();
	const [step, setStep] = useState<"pick" | "review">("pick");
	const reviewRef = useRef<HTMLHeadingElement>(null);
	const prevStep = useRef(step);
	// Focus follows the step so a screen reader announces where it landed, and
	// only when it changed: the page's own load must not steal focus. Comparing
	// steps (not a first-run flag) holds when StrictMode runs the effect twice.
	useEffect(() => {
		if (prevStep.current === step) {
			return;
		}
		prevStep.current = step;
		(step === "review" ? reviewRef : backFocus)?.current?.focus();
	}, [step, backFocus]);

	if (step === "pick") {
		return (
			<>
				{fields}
				{picker ? (
					<VaultAccessFields
						access={access}
						vaults={vaults}
						legend={legend}
						leveled={leveled}
						lockReadOnly={lockReadOnly}
					/>
				) : null}
				{reachesNothing ? (
					<p id={reasonId} className="text-muted-foreground text-xs">
						{t("Choose at least one vault.")}
					</p>
				) : null}
				<footer className="flex gap-3">
					{onCancel ? (
						<Button type="button" variant="outline" onClick={onCancel} className="flex-1">
							{t("Cancel")}
						</Button>
					) : null}
					<Button
						type="button"
						onClick={() => setStep("review")}
						disabled={reachesNothing || !ready}
						aria-describedby={reachesNothing ? reasonId : undefined}
						className="flex-1"
					>
						{t("Review")}
					</Button>
				</footer>
			</>
		);
	}

	const confirmText = pending ? pendingLabel : confirmLabel;
	return (
		<section aria-labelledby={headingId} className="flex flex-col gap-5">
			<h2
				id={headingId}
				ref={reviewRef}
				tabIndex={-1}
				className="font-semibold text-foreground text-lg outline-none"
			>
				{t("{name} will be able to:", { name })}
			</h2>
			<AccessSummary
				vaults={vaults}
				perVault={access.perVault}
				readOnly={leveled && maxLevel === "read"}
				levelOf={(id) => (leveled ? capLevel(access.levelOf(id), maxLevel) : access.levelOf(id))}
				later={leveled ? capLevel(access.later, maxLevel) : "none"}
			/>
			{settingsHint ? (
				<p className="text-muted-foreground text-sm">
					{t("You can change or revoke this anytime in Settings > Connections.")}
				</p>
			) : null}
			{error}
			<footer className="flex gap-3">
				<Button
					type="button"
					variant="outline"
					onClick={() => setStep("pick")}
					disabled={pending}
					className="flex-1"
				>
					{t("Back")}
				</Button>
				<Button
					type="button"
					onClick={onConfirm}
					disabled={pending || reachesNothing}
					className="flex-1"
				>
					{confirmText}
				</Button>
			</footer>
		</section>
	);
}
