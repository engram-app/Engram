import { type ReactNode, useState } from "react";
import { track } from "../analytics/track";
import { ChecklistWidget } from "./checklist-widget";
import { CreateFirstVaultModal } from "./create-first-vault-modal";
import { SurveyPrompt } from "./survey-modal";
import { useOnboardingActions } from "./use-onboarding-actions";

export function OnboardingShell({ children }: { children: ReactNode }) {
	const ob = useOnboardingActions();
	const [vaultModalHandled, setVaultModalHandled] = useState(false);

	if (ob.isLoading) {
		return <>{children}</>;
	}

	// Not for a plugin-first signup: its plugin's first sync creates the vault,
	// and one made here would be refused by the Free cap when the plugin
	// registers its own.
	const showVaultModal = !(vaultModalHandled || ob.pluginFirst) && ob.vaultCount === 0;

	return (
		<>
			{children}
			{Boolean(showVaultModal) && (
				<CreateFirstVaultModal
					onCreated={(vault) => {
						// Same milestone the wizard's own vault step reports (see
						// onboard-vault-page.tsx), reached here via the recovery path:
						// a "done" account with 0 vaults (e.g. after a deletion).
						track("onboarding_step_completed", { step: "vault", vault_id: vault.id });
						setVaultModalHandled(true);
					}}
				/>
			)}
			<ChecklistWidget />
			<SurveyPrompt suppressed={showVaultModal} />
		</>
	);
}
