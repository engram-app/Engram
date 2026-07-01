import { useState, type FormEvent } from "react";
import { Link, useSearchParams } from "react-router";
import AuthShell from "@/layout/auth-shell";
import AuthPanel from "@/layout/auth-panel";
import { Button } from "@/components/ui/button";
import { heading, fieldInput, destructiveAlert } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { ROUTES } from "@/routes";
import { getApiBase, joinApiUrl } from "@/api/base";

export default function ResetPasswordPage() {
	const [params] = useSearchParams();
	const token = params.get("token") ?? "";
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
						<p className="text-sm text-muted-foreground">
							You can sign in with your new password now. Any old sessions have been signed out.
						</p>
						<Link
							to={ROUTES.SIGN_IN}
							className="inline-block rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
						>
							Sign in
						</Link>
					</section>
				) : (
					<form onSubmit={submit} className="space-y-4">
						<div className="text-center">
							<h1 className={heading}>Set a new password</h1>
							<p className="mt-1 text-sm text-muted-foreground">
								Choose something at least 8 characters long.
							</p>
						</div>

						{error && (
							<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
								{error}
							</p>
						)}

						<label className="block">
							<span className="text-sm font-medium text-foreground">New password</span>
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
							<span className="text-sm font-medium text-foreground">Confirm password</span>
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
