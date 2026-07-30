import { Navigate, useLocation } from "react-router";
import { parseSettingsHash, settingsHash } from "./settings-hash";

// `/settings/*` was the old path route. Phoenix still serves the SPA for those
// paths (see router.ex) so existing bookmarks boot, and this bounces them to the
// hash form. Redirects to `/`, which VaultRedirect then resolves to the user's
// vault while preserving the hash.
export default function LegacySettingsRedirect() {
	const location = useLocation();
	const tail = location.pathname.replace(/^\/settings\/?/, "");
	const section = parseSettingsHash(tail === "" ? "#settings" : `#settings/${tail}`) ?? "account";

	return (
		<Navigate
			to={{ pathname: "/", search: location.search, hash: settingsHash(section) }}
			replace
		/>
	);
}
