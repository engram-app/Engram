import { type FormEvent, useEffect, useState } from "react";
import { Link, useLocation, useNavigate, useSearchParams } from "react-router";
import { getApiBase, joinApiUrl } from "@/api/base";
import { Button } from "@/components/ui/button";
import AuthPanel from "@/layout/auth-panel";
import AuthShell from "@/layout/auth-shell";
import { destructiveAlert, fieldInput, heading } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { ROUTES } from "@/routes";

export default function ResetPasswordPage() {
	const [params] = useSearchParams();
	const location = useLocation();
	const navigate = useNavigate();
	// Captured once, then scrubbed from the URL. The token IS the credential
	// that lets the bearer set this account's password, and while it sits in
	// the address bar it is in browser history, in the Referer of anything the
	// page loads, and attached to every Sentry event as request.url. Held in
	// state so the scrub cannot pull it out from under the submit handler.
	const [token] = useState(() => params.get("token") ?? "");

	useEffect(() => {
		if (!params.has("token")) {
			return;
		}
		const next = new URLSearchParams(location.search);
		next.delete("token");
		// Through the router, not window.history: this app runs on a data
		// router, which does not observe a raw replaceState.
		navigate(
			{ pathname: location.pathname, search: next.toString(), hash: location.hash },
			{ replace: true },
		);
	}, [params, location, navigate]);
	const [password, setPassword] = useState("");
	const [confirm, setConfirm] = useState("");
	const [error, setError] = useState("");
	const [loading, setLoading] = useState(false);
	const [done, setDone] = useState(false);

	async function submit(e: FormEvent) {
		e.preventDefault();
		setError("");

		if (!token) {
			setError("This reset link is missing its token.");
			return;
		}

		if (password !== confirm) {
			setError("Passwords do not match");
			return;
		}

		setLoading(true);
		try {
			const res = await fetch(joinApiUrl(getApiBase(), "/api/auth/password/reset"), {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ token, password }),
			});

			if (res.ok) {
				setDone(true);
			} else {
				const body = await res.json().catch(() => ({}));
				// 422 invalid_token is the common case — keep the copy non-leaky.
				setError(
					body.error === "invalid_token"
						? "This reset link is invalid or expired."
						: (body.error ?? "Could not reset password"),
				);
			}
		} catch {
			setError("Could not reach the server");
		} finally {
			setLoading(false);
		}
	}

	return (
		<AuthShell navLabel="Reset password">
			<AuthPanel>
				{done ? (
					<section className="space-y-3 text-center">
						<h1 className={heading}>Password updated</h1>
						<p className="text-muted-foreground text-sm">
							You can sign in with your new password now. Any old sessions have been signed out.
						</p>
						<Link
							to={ROUTES.SIGN_IN}
							className="inline-block rounded-md bg-primary px-4 py-2 font-medium text-primary-foreground text-sm hover:bg-primary/90"
						>
							Sign in
						</Link>
					</section>
				) : (
					<form onSubmit={submit} className="space-y-4">
						<div className="text-center">
							<h1 className={heading}>Set a new password</h1>
							<p className="mt-1 text-muted-foreground text-sm">
								Choose something at least 8 characters long.
							</p>
						</div>

						{Boolean(error) && (
							<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
								{error}
							</p>
						)}

						<label className="block">
							<span className="font-medium text-foreground text-sm">New password</span>
							<input
								type="password"
								required
								minLength={8}
								value={password}
								onChange={(e) => setPassword(e.target.value)}
								className={cn("mt-1 block", fieldInput)}
							/>
						</label>

						<label className="block">
							<span className="font-medium text-foreground text-sm">Confirm password</span>
							<input
								type="password"
								required
								value={confirm}
								onChange={(e) => setConfirm(e.target.value)}
								className={cn("mt-1 block", fieldInput)}
							/>
						</label>

						<Button type="submit" disabled={loading} className="w-full">
							{loading ? "Updating…" : "Set password"}
						</Button>
					</form>
				)}
			</AuthPanel>
		</AuthShell>
	);
}
