import { useT } from "@/i18n/locale-provider";
import type { Vault } from "../api/queries";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogHeader,
	DialogTitle,
} from "../components/ui/dialog";
import { VaultCreateForm } from "../components/vault-create-form";

interface Props {
	onCreated: (vault: Vault) => void;
}

export function CreateFirstVaultModal({ onCreated }: Props) {
	const { t } = useT();
	return (
		<Dialog open>
			<DialogContent
				className="sm:max-w-md"
				showCloseButton={false}
				onEscapeKeyDown={(e) => e.preventDefault()}
				onPointerDownOutside={(e) => e.preventDefault()}
				onInteractOutside={(e) => e.preventDefault()}
			>
				<DialogHeader>
					<DialogTitle>{t("Create your first vault")}</DialogTitle>
					<DialogDescription>
						{t("A vault holds your notes. You can rename it or add more later.")}
					</DialogDescription>
				</DialogHeader>
				<VaultCreateForm autoFocus submitLabel={t("Create vault")} onCreated={onCreated} />
			</DialogContent>
		</Dialog>
	);
}
