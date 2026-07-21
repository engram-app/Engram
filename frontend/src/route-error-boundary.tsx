import { useEffect, useState } from "react";
import { isRouteErrorResponse, useRouteError } from "react-router";
import ErrorFallback from "./error-fallback";
import { captureError } from "./sentry";

// The router's global errorElement. React Router's data router intercepts any
// throw during a route's render before it can reach the root RootErrorBoundary
// (main.tsx), so without this a route crash (e.g. a decoration bug in the note
// editor) fell through to React Router's bare default error page. Mounted once
// at the root route, it catches every descendant route error and renders the
// same ErrorFallback the root boundary uses — one crash page for the whole app.
export default function RouteErrorBoundary() {
	const error = useRouteError();
	const [report, setReport] = useState<{ eventId?: string; reported: boolean }>({
		reported: false,
	});

	useEffect(() => {
		// New route error → clear any prior error's eventId/reported. RR updates
		// useRouteError in place (the errorElement instance persists across
		// sequential route errors), so without this a later crash could briefly
		// show the previous crash's reference id.
		setReport({ reported: false });
		// isRouteErrorResponse => an expected HTTP-shaped throw. Skip Sentry for
		// CLIENT errors (404 / redirect); a SERVER error (5xx) is a real failure,
		// so let it fall through and report. (Latent until a data loader throws a
		// Response — element routes don't today.)
		if (isRouteErrorResponse(error) && error.status < 500) {
			return;
		}
		let alive = true;
		captureError(error).then((eventId) => {
			if (alive && eventId) {
				setReport({ eventId, reported: true });
			}
		});
		return () => {
			alive = false;
		};
	}, [error]);

	return <ErrorFallback error={error} eventId={report.eventId} reported={report.reported} />;
}
