import { type FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import type { Translate } from "@/i18n/translate";
import { destructiveAlert, heading } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { ROUTES } from "../routes";
import AuthLayout from "./auth-layout";
import { safeReturnTo } from "./safe-return-to";
import { authUrlWithReturnTo } from "./sign-in-redirect";
import { useAuthAdapter } from "./use-auth-adapter";
import { type BootstrapState, useBootstrap } from "./use-bootstrap";

// `code` is an API error code or one of the English fallbacks thrown by the
// auth provider; anything unrecognized (a server-written message) shows as-is.
function loginErrorMessage(code: string, t: Translate): string {
	switch (code) {
		case "account_suspended":
			return t("This account is suspended. Contact an admin to restore access.");
		case "invalid_credentials":
			return t("Incorrect email or password.");
		case "Login failed":
			return t("Login failed");
		case "Login not available for this auth provider":
			return t("Login not available for this auth provider");
		default:
			return code;
	}
}

// Mode-aware sign-up prompt. While bootstrap is `undefined` we render an
// invisible placeholder line of the same height — preserves layout and
// avoids the default→correct copy flash on first paint. `null` means
// Clerk / 404 / network error: fall back to the open-mode link.
function SignUpFooter({ bootstrap, returnTo }: { bootstrap: BootstrapState; returnTo: string }) {
	const { t } = useT();
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
			<p className="text-center text-muted-foreground text-sm">
				{t("Sign-ups require an invite link. Contact your admin to request one.")}
			</p>
		);
	}
	if (mode === "closed") {
		return (
			<p className="text-center text-muted-foreground text-sm">
				{t("Sign-ups are closed on this instance.")}
			</p>
		);
	}
	return (
		<p className="text-center text-muted-foreground text-sm">
			<Trans
				text="Don't have an account? {signup}"
				slots={{
					signup: (
						<Link
							to={authUrlWithReturnTo(ROUTES.SIGN_UP, returnTo)}
							className="font-medium text-primary hover:underline"
						>
							{t("Sign up")}
						</Link>
					),
				}}
			/>
		</p>
	);
}

export default function LocalSignIn() {
	const { t } = useT();
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
		if (isSignedIn) {
			navigate(returnTo, { replace: true });
		}
	}, [isSignedIn, navigate, returnTo]);

	// Self-host first-run: bounce to /sign-up so the operator creates the
	// admin account instead of staring at an unusable sign-in form.
	//
	// Carries `return_to` for the same reason the visible link below does —
	// this is the SECOND /sign-in -> /sign-up hop, and a bare one strands a
	// first-run operator who arrived holding a destination (e.g. the plugin's
	// /link?code=, stashed by AuthGuard and never redeemed if we drop it).
	useEffect(() => {
		if (bootstrap?.bootstrap_pending) {
			navigate(authUrlWithReturnTo(ROUTES.SIGN_UP, returnTo), { replace: true });
		}
	}, [bootstrap, navigate, returnTo]);

	async function handleSubmit(e: FormEvent) {
		e.preventDefault();
		setError("");
		setLoading(true);

		try {
			if (!login) {
				throw new Error("Login not available for this auth provider");
			}
			await login(email, password);
		} catch (err) {
			const raw = err instanceof Error ? err.message : "Login failed";
			setError(loginErrorMessage(raw, t));
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
					<h1 className={heading}>{t("Sign in to Engram")}</h1>
				</div>

				{Boolean(error) && (
					<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
						{error}
					</p>
				)}

				<label className="block">
					<span className="font-medium text-foreground text-sm">{t("Email")}</span>
					<Input
						type="email"
						required
						value={email}
						onChange={(e) => setEmail(e.target.value)}
						className="mt-1 block"
					/>
				</label>

				<label className="block">
					<span className="font-medium text-foreground text-sm">{t("Password")}</span>
					<Input
						type="password"
						required
						value={password}
						onChange={(e) => setPassword(e.target.value)}
						className="mt-1 block"
					/>
				</label>

				<Button type="submit" disabled={loading} className="w-full">
					{loading ? t("Signing in…") : t("Sign in")}
				</Button>

				<SignUpFooter bootstrap={bootstrap} returnTo={returnTo} />
			</form>
		</AuthLayout>
	);
}
