import {
	type OnboardingAction,
	useOnboardingStatus,
	useRecordOnboardingAction,
} from "../api/queries";

export function useOnboardingActions() {
	const { data, isLoading } = useOnboardingStatus();
	const { mutateAsync } = useRecordOnboardingAction();

	const actions = new Set<OnboardingAction>(data?.actions ?? []);

	return {
		isLoading,
		vaultCount: data?.vault_count ?? 0,
		// A plugin-first signup still on Obsidian: its plugin creates the vault
		// on first sync, once the parked /link code is approved.
		pluginFirst: data?.profile?.signup_source === "plugin" && data.profile.uses_obsidian === true,
		has: (a: OnboardingAction) => actions.has(a),
		recordAsync: mutateAsync,
	};
}
