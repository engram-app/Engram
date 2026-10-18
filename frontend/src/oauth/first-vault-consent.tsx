import { type FormEvent, type ReactNode, useId, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";

interface Props {
	client: string;
	/** The vault provisioned at signup, the account's only one. */
	vaultName: string;
	pending: boolean;
	error: ReactNode;
	/** `onlyThisVault`: the user unticked access to vaults created later. */
	onApprove: (vaultName: string, onlyThisVault: boolean) => Promise<void>;
	onCancel?: () => void;
}

// First connection on a brand-new account: one vault, nothing in it worth
// scoping yet. The all/choose picker and its review step ask a question this
// user has no basis to answer. What is left: the vault's name, and whether the
// app also reaches vaults made later (on by default, the same as the picker's
// All vaults). Read and write either way; the connections page narrows it.
export default function FirstVaultConsent({
	client,
	vaultName,
	pending,
	error,
	onApprove,
	onCancel,
}: Props) {
	const { t } = useT();
	const inputId = useId();
	const hintId = useId();
	const laterId = useId();
	const laterHintId = useId();
	const [name, setName] = useState(vaultName);
	const [includeLater, setIncludeLater] = useState(true);
	const trimmed = name.trim();

	const submit = (e: FormEvent) => {
		e.preventDefault();
		// The disabled button already blocks a second click; this blocks a
		// second Enter, which would open a second tab and rename twice.
		if (trimmed && !pending) {
			onApprove(trimmed, !includeLater);
		}
	};

	return (
		<form onSubmit={submit} className="flex flex-col gap-4">
			<p className="flex flex-col gap-1">
				<label htmlFor={inputId} className="font-semibold text-foreground text-lg">
					{t("Name your first vault")}
				</label>
				<span id={hintId} className="text-foreground/80">
					{t("A vault is a collection of notes. {client} can read and write the notes in it.", {
						client,
					})}
				</span>
			</p>
			<Input
				id={inputId}
				type="text"
				maxLength={120}
				value={name}
				aria-describedby={hintId}
				onChange={(e) => setName(e.target.value)}
			/>
			{/* A real decision about future vaults, so a full row, not a footnote. */}
			<label
				htmlFor={laterId}
				className="flex cursor-pointer items-center gap-3 rounded-md border border-border bg-muted/30 p-3 has-checked:border-primary/60"
			>
				<input
					id={laterId}
					type="checkbox"
					checked={includeLater}
					aria-describedby={laterHintId}
					onChange={(e) => setIncludeLater(e.target.checked)}
					className="size-4 shrink-0 accent-primary"
				/>
				<span className="flex flex-col gap-0.5">
					<span className="font-medium text-foreground">
						{t("Also allow {client} to read and write vaults I create later", { client })}
					</span>
					<span id={laterHintId} className="text-muted-foreground text-sm">
						{t("Turn this off to keep {client} to this vault only.", { client })}
					</span>
				</span>
			</label>
			<p className="text-muted-foreground text-xs">
				{t("You can limit what each app can see or change anytime in Settings > Connections.")}
			</p>
			{error}
			<footer className="flex gap-3">
				{onCancel ? (
					<Button type="button" variant="outline" onClick={onCancel} className="flex-1">
						{t("Cancel")}
					</Button>
				) : null}
				<Button type="submit" disabled={!trimmed || pending} className="flex-1">
					{pending ? t("Approving…") : t("Approve")}
				</Button>
			</footer>
		</form>
	);
}
