import type { Translate } from "./translate";

// The server stores the default vault name in English so the API, MCP and the
// plugin all see one stable value. Only the display is translated, so it
// follows the language picker.
export const DEFAULT_VAULT_NAME = "My Vault";

export function displayVaultName(name: string, t: Translate): string {
	return name === DEFAULT_VAULT_NAME ? t("My Vault") : name;
}
