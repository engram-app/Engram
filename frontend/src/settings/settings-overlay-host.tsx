import { lazy, Suspense } from "react";
import { Outlet, useLocation } from "react-router";
import { parseSettingsHash } from "./settings-hash";

// Settings is a hash overlay, not a page: the route underneath stays mounted, so
// closing returns you exactly where you were. Mounted at the AuthGuard level
// rather than inside AppLayout because /link and /oauth/consent both link to
// `#settings/billing` and live outside the app shell.
const SettingsDialog = lazy(() => import("./settings-layout"));

export default function SettingsOverlayHost() {
	const { hash } = useLocation();
	const section = parseSettingsHash(hash);

	return (
		<>
			<Outlet />
			{section !== null && (
				<Suspense fallback={null}>
					<SettingsDialog section={section} />
				</Suspense>
			)}
		</>
	);
}
