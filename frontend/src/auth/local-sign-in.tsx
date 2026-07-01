import { type FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import { destructiveAlert, fieldInput, heading } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { ROUTES } from "../routes";
import AuthLayout from "./auth-layout";
import { safeReturnTo } from "./safe-return-to";
import { useAuthAdapter } from "./use-auth-adapter";
import { type BootstrapState, useBootstrap } from "./use-bootstrap";

function loginErrorMessage(code: string): string {
	switch (code) {
		case "account_suspended":
			return "This account is suspended. Contact an admin to restore access.";
		case "invalid_credentials":
			return "Incorrect email or password.";
		default:
			return code;
	}
}

export default function LocalSignIn() {
	const { login, isSignedIn } = useAuthAdapter();
	const navigate = useNavigate();
	const [searchParams] = useSearchParams();
	const returnTo = safeReturnTo(searchParams.get("return_to"));
	const bootstrap = useBootstrap();
	const [email, setEmail] = useState("");
	const [password, setPassword] = useState("");
	const [error, setError] = useState("");
	const [loading, setLoading] = useState(false);

	// Navigate after auth state propagates (React 18 batching)
	useEffect(() => {
		if (isSignedIn) navigate(returnTo, { replace: true });
	}, [isSignedIn, navigate, returnTo]);

	// Self-host first-run: bounce to /sign-up so the operator creates the
	// admin account instead of staring at an unusable sign-in form.
	useEffect(() => {
		if (bootstrap?.bootstrap_pending) {
			navigate(ROUTES.SIGN_UP, { replace: true });
		}
	}, [bootstrap, navigate]);

	async function handleSubmit(e: FormEvent) {
		e.preventDefault();
		setError("");
		setLoading(true);

		try {
			if (!login) throw new Error("Login not available for this auth provider");
			await login(email, password);
		} catch (err) {
			const raw = err instanceof Error ? err.message : "Login failed";
			setError(loginErrorMessage(raw));
		} finally {
			setLoading(false);
		}
	}

	return (
		<AuthLayout>
			<form
				onSubmit={handleSubmit}
				className="w-full max-w-sm space-y-4 rounded-2xl border border-border bg-card p-6 shadow-sm sm:p-8"
			>
				<div className="flex flex-col items-center gap-2 text-center">
					<img src="/engram-mark.svg" alt="Engram" className="size-12" />
					<h1 className={heading}>Sign in to Engram</h1>
				</div>

				{error && (
					<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
						{error}
					</p>
				)}

				<label className="block">
					<span className="text-sm font-medium text-foreground">Email</span>
					<input
						type="email"
						required
						value={email}
						onChange={(e) => setEmail(e.target.value)}
						className={cn("mt-1 block", fieldInput)}
					/>
				</label>

				<label className="block">
					<span className="text-sm font-medium text-foreground">Password</span>
					<input
						type="password"
						required
						value={password}
						onChange={(e) => setPassword(e.target.value)}
						className={cn("mt-1 block", fieldInput)}
					/>
				</label>

				<Button type="submit" disabled={loading} className="w-full">
					{loading ? "Signing in…" : "Sign in"}
				</Button>

				<SignUpFooter bootstrap={bootstrap} />
			</form>
		</AuthLayout>
	);
}

// Mode-aware sign-up prompt. While bootstrap is `undefined` we render an
// invisible placeholder line of the same height — preserves layout and
// avoids the default→correct copy flash on first paint. `null` means
// Clerk / 404 / network error: fall back to the open-mode link.
function SignUpFooter({ bootstrap }: { bootstrap: BootstrapState }) {
	if (bootstrap === undefined) {
		return (
			<p aria-hidden className="invisible text-center text-sm">
				&nbsp;
			</p>
		);
	}
	const mode = bootstrap?.registration_mode;
	if (mode === "invite_only") {
		return (
			<p className="text-center text-sm text-muted-foreground">
				Sign-ups require an invite link. Contact your admin to request one.
			</p>
		);
	}
	if (mode === "closed") {
		return (
			<p className="text-center text-sm text-muted-foreground">
				Sign-ups are closed on this instance.
			</p>
		);
	}
	return (
		<p className="text-center text-sm text-muted-foreground">
			Don't have an account?{" "}
			<Link to={ROUTES.SIGN_UP} className="font-medium text-primary hover:underline">
				Sign up
			</Link>
		</p>
	);
}
