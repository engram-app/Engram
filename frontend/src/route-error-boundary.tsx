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
		// isRouteErrorResponse => an expected HTTP-shaped throw (404 / redirect
		// Response), not a crash. Show the page but don't page Sentry for it.
		if (isRouteErrorResponse(error)) {
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
