import { CreditCard, type LucideIcon, Plug, ShieldCheck, User, Vault } from "lucide-react";
import { msg } from "@/i18n/msg";
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
		{ key: "account", label: msg("Account"), icon: User },
		{ key: "vaults", label: msg("Vaults"), icon: Vault },
		{ key: "connections", label: msg("Connections"), icon: Plug },
	];

	if (billingEnabled) {
		sections.push({ key: "billing", label: msg("Billing"), icon: CreditCard });
	}

	if (authProvider === "local" && isAdmin) {
		sections.push({ key: "admin", label: msg("Administration"), icon: ShieldCheck });
	}

	return sections;
}
