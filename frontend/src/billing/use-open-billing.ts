import { useLocation, useNavigate } from "react-router";
import { settingsTo } from "@/settings/settings-hash";
import type { UpgradeSource } from "../analytics/events";
import { track } from "../analytics/track";
import { noteUpgradeSource } from "./upgrade-source";

/** Opens the billing settings from an upgrade prompt, recording where from. */
export function useOpenBilling(source: UpgradeSource): () => void {
	const navigate = useNavigate();
	const location = useLocation();
	return () => {
		track("upgrade_link_clicked", { source });
		noteUpgradeSource(source);
		navigate(settingsTo("billing", location.search));
	};
}
