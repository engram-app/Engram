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
	onApprove: (vaultName: string) => Promise<void>;
	onCancel?: () => void;
}

// First connection on a brand-new account: one vault, nothing in it worth
// scoping yet. The all/choose picker and its review step ask a question this
// user has no basis to answer, so the only choice offered is the vault's name;
// access is the default (every vault, read and write), and the connections
// page is where they narrow it later.
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
	const [name, setName] = useState(vaultName);
	const trimmed = name.trim();

	const submit = (e: FormEvent) => {
		e.preventDefault();
		if (trimmed) {
			onApprove(trimmed);
		}
	};

	return (
		<form onSubmit={submit} className="flex flex-col gap-4">
			<p className="flex flex-col gap-1.5">
				<label htmlFor={inputId} className="font-medium text-foreground text-sm">
					{t("Name your first vault")}
				</label>
				<span id={hintId} className="text-muted-foreground text-sm">
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
