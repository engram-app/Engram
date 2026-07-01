import { type ReactNode, useState } from "react";
import { useNavigate } from "react-router";
import { useCreateVault } from "../api/queries";
import { ChecklistWidget } from "./checklist-widget";
import { CreateFirstVaultModal } from "./create-first-vault-modal";
import { TourController } from "./tour/controller";
import { DemoVaultProvider, useDemoVault } from "./tour/demo-vault-provider";
import { useOnboardingActions } from "./use-onboarding-actions";

function ShellInner({ children }: { children: ReactNode }) {
	const ob = useOnboardingActions();
	const demo = useDemoVault();
	const createVault = useCreateVault();
	const navigate = useNavigate();

	const [tourActive, setTourActive] = useState(false);
	const [tourReachedEnd, setTourReachedEnd] = useState(false);
	const [vaultModalHandled, setVaultModalHandled] = useState(false);

	if (ob.isLoading) {
		return <>{children}</>;
	}

	const showVaultModal = !vaultModalHandled && ob.vaultCount === 0 && !tourActive;

	const startTour = async () => {
		await demo.activate();
		setTourActive(true);
	};

	const onTourExit = (reachedEnd: boolean) => {
		if (reachedEnd) {
			ob.record("tour_completed");
		}
		setTourActive(false);
		demo.deactivate();
		// The tour walks through a demo note (`/note/<id>`) that doesn't exist
		// in the real backend. Bounce back to the dashboard so useNote doesn't
		// 404 once the demo wrap drops.
		navigate("/", { replace: true });
		// Tour CTA promised "Create my vault" — fulfill it. Spin up a default
		// vault so the user lands on a real dashboard, not a blocking modal.
		// User can rename it later in /settings/vaults.
		if (reachedEnd && ob.vaultCount === 0) {
			setVaultModalHandled(true);
			createVault.mutate({ name: "My Vault" });
		}
	};

	return (
		<>
			{children}
			{Boolean(tourActive) && (
				<TourController
					active={tourActive}
					reachedEnd={tourReachedEnd}
					setReachedEnd={setTourReachedEnd}
					onExit={onTourExit}
				/>
			)}
			{Boolean(showVaultModal) && (
				<CreateFirstVaultModal onCreated={() => setVaultModalHandled(true)} />
			)}
			{!tourActive && <ChecklistWidget onStartTour={startTour} />}
		</>
	);
}

export function OnboardingShell({ children }: { children: ReactNode }) {
	return (
		<DemoVaultProvider>
			<ShellInner>{children}</ShellInner>
		</DemoVaultProvider>
	);
}
