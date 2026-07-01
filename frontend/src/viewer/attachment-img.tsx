import { useEffect, useState } from "react";
import { ApiError, api } from "../api/client";

// 'missing' only for a real 404; a transient 5xx/network failure must NOT claim
// the file is missing (the file exists, storage is just unreachable).
type LoadError = "missing" | "failed";

export default function AttachmentImg({ path, alt }: { path: string; alt?: string }) {
	const [src, setSrc] = useState<string | null>(null);
	const [error, setError] = useState<LoadError | null>(null);

	useEffect(() => {
		let revoke: string | null = null;
		let cancelled = false;
		const encoded = path.split("/").map(encodeURIComponent).join("/");
		api
			.getBlob(`/attachments/${encoded}?raw=1`)
			.then((blob) => {
				if (cancelled) return;
				const url = URL.createObjectURL(blob);
				revoke = url;
				setSrc(url);
			})
			.catch((err) => {
				if (cancelled) return;
				// A non-ApiError is a bug (e.g. createObjectURL), not a load failure.
				if (!(err instanceof ApiError)) console.error("attachment image load failed", path, err);
				setError(err instanceof ApiError && err.status === 404 ? "missing" : "failed");
			});
		return () => {
			cancelled = true;
			if (revoke) URL.revokeObjectURL(revoke);
		};
	}, [path]);

	if (error) {
		return (
			<span className="inline-flex items-center gap-1 rounded bg-destructive/10 px-1.5 py-0.5 text-xs text-destructive">
				{error === "missing"
					? `Missing attachment: ${path}`
					: `Couldn't load ${path} (temporarily unavailable)`}
			</span>
		);
	}
	if (!src) {
		return <span className="text-xs text-muted-foreground">Loading {path}…</span>;
	}
	return <img src={src} alt={alt ?? path} className="my-2 max-w-full rounded" />;
}
