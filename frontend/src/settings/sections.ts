import type { EngramConfig } from "../config";
import type { SettingsSectionKey } from "./settings-hash";

export interface SettingsSection {
	key: SettingsSectionKey;
	label: string;
}

export function buildSettingsSections(
	authProvider: EngramConfig["authProvider"],
	billingEnabled: boolean,
	isAdmin = false,
): SettingsSection[] {
	const sections: SettingsSection[] = [
		{ key: "account", label: "Account" },
		{ key: "vaults", label: "Vaults" },
		{ key: "connections", label: "Connections" },
	];

	if (billingEnabled) {
		sections.push({ key: "billing", label: "Billing" });
	}

	if (authProvider === "local" && isAdmin) {
		sections.push({ key: "admin", label: "Administration" });
	}

	return sections;
}
