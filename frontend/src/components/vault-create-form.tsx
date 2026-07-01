import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useCreateVault } from "@/api/queries";

const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

interface Props {
	onCreated?: (vaultId: string) => void;
	onCancel?: () => void;
	submitLabel?: string;
	autoFocus?: boolean;
	showCancel?: boolean;
}

export function VaultCreateForm({
	onCreated,
	onCancel,
	submitLabel = "Create",
	autoFocus = false,
	showCancel = false,
}: Props) {
	const create = useCreateVault();
	const [name, setName] = useState("");

	function submit(e: React.FormEvent) {
		e.preventDefault();
		const next = name.trim();
		if (!next) return;
		create.mutate(
			{ name: next },
			{
				onSuccess: (res) => {
					toast.success("Vault created");
					setName("");
					onCreated?.(res.vault.id);
				},
				onError: (e) => {
					// 402 cap errors are already surfaced by UpgradeDialogProvider via
					// the central LimitExceededError handler — don't double-render as a
					// toast.
					if (e instanceof Error && e.name === "LimitExceededError") return;
					toast.error("Could not create vault");
				},
			},
		);
	}

	return (
		<form className="flex flex-col" onSubmit={submit}>
			<label className="block text-sm font-medium text-foreground">
				Vault name
				<input
					className={inputClass}
					aria-label="Vault name"
					autoFocus={autoFocus}
					value={name}
					onChange={(e) => setName(e.target.value)}
					disabled={create.isPending}
				/>
			</label>
			<div className="mt-3 flex gap-2">
				<Button type="submit" size="sm" disabled={create.isPending || !name.trim()}>
					{create.isPending ? "Creating…" : submitLabel}
				</Button>
				{showCancel && (
					<Button type="button" variant="ghost" size="sm" onClick={onCancel}>
						Cancel
					</Button>
				)}
			</div>
		</form>
	);
}
