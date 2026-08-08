import { type ReactNode, useState } from "react";
import { ChecklistWidget } from "./checklist-widget";
import { CreateFirstVaultModal } from "./create-first-vault-modal";
import { useOnboardingActions } from "./use-onboarding-actions";

export function OnboardingShell({ children }: { children: ReactNode }) {
	const ob = useOnboardingActions();
	const [vaultModalHandled, setVaultModalHandled] = useState(false);

	if (ob.isLoading) {
		return <>{children}</>;
	}

	const showVaultModal = !vaultModalHandled && ob.vaultCount === 0;

	return (
		<>
			{children}
			{Boolean(showVaultModal) && (
				<CreateFirstVaultModal onCreated={() => setVaultModalHandled(true)} />
			)}
			<ChecklistWidget />
		</>
	);
}
