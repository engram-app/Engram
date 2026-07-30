import { CreditCard, type LucideIcon, Plug, ShieldCheck, User, Vault } from "lucide-react";
import type { EngramConfig } from "../config";
import type { SettingsSectionKey } from "./settings-hash";

export interface SettingsSection {
	key: SettingsSectionKey;
	label: string;
	// The nav's leading glyph. Lives here rather than in settings-layout so the
	// section list stays the single place a new section is declared.
	icon: LucideIcon;
}

export function buildSettingsSections(
	authProvider: EngramConfig["authProvider"],
	billingEnabled: boolean,
	isAdmin = false,
): SettingsSection[] {
	const sections: SettingsSection[] = [
		{ key: "account", label: "Account", icon: User },
		{ key: "vaults", label: "Vaults", icon: Vault },
		{ key: "connections", label: "Connections", icon: Plug },
	];

	if (billingEnabled) {
		sections.push({ key: "billing", label: "Billing", icon: CreditCard });
	}

	if (authProvider === "local" && isAdmin) {
		sections.push({ key: "admin", label: "Administration", icon: ShieldCheck });
	}

	return sections;
}
