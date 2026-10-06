import { type FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";
import type { Translate } from "@/i18n/translate";
import { destructiveAlert, fieldInput, heading } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { getApiBase, joinApiUrl } from "../api/base";
import { ROUTES } from "../routes";
import AuthLayout from "./auth-layout";
import { safeReturnTo } from "./safe-return-to";
import { authUrlWithReturnTo } from "./sign-in-redirect";
import { useAuthAdapter } from "./use-auth-adapter";
import { useBootstrap } from "./use-bootstrap";

interface InvitePreview {
	valid: boolean;
	label?: string | null;
}

// `raw` is a server-written message or one of the English fallbacks thrown by
// the auth provider; only the fallbacks are ours to translate.
function registrationErrorMessage(raw: string, t: Translate): string {
	switch (raw) {
		case "Registration failed":
			return t("Registration failed");
		case "Registration not available for this auth provider":
			return t("Registration not available for this auth provider");
		default:
			return raw;
	}
}

export default function LocalSignUp() {
	const { t } = useT();
	const { register, isSignedIn } = useAuthAdapter();
	const navigate = useNavigate();
	const [searchParams] = useSearchParams();
	const invite = searchParams.get("invite") ?? "";
	// Mirrors local-sign-in.tsx. Landing unconditionally on HOME dropped an
	// in-flight OAuth authorization for anyone who signed up mid-flow.
	const returnTo = safeReturnTo(searchParams.get("return_to"));
	const bootstrap = useBootstrap();
	// Keyed by the invite it was fetched for, so switching to a different (or
	// absent) invite yields null during render instead of leaving the previous
	// invite's banner up until an effect clears it.
	const [fetchedPreview, setFetchedPreview] = useState<{
		invite: string;
		preview: InvitePreview;
	} | null>(null);
	const invitePreview = invite && fetchedPreview?.invite === invite ? fetchedPreview.preview : null;
	const [email, setEmail] = useState("");
	const [password, setPassword] = useState("");
	const [confirm, setConfirm] = useState("");
	const [error, setError] = useState("");
	const [loading, setLoading] = useState(false);

	// Navigate after auth state propagates (React 18 batching)
	useEffect(() => {
		if (isSignedIn) {
			navigate(returnTo, { replace: true });
		}
	}, [isSignedIn, navigate, returnTo]);

	// Preview the invite (non-enumerating: bad/expired/revoked → {valid:false}).
	useEffect(() => {
		if (!invite) {
			return;
		}
		fetch(joinApiUrl(getApiBase(), `/api/auth/invite/${encodeURIComponent(invite)}`))
			.then((r) => r.json())
			.then((p: InvitePreview) => setFetchedPreview({ invite, preview: p }))
			.catch(() => setFetchedPreview({ invite, preview: { valid: false } }));
	}, [invite]);

	async function handleSubmit(e: FormEvent) {
		e.preventDefault();
		setError("");

		if (password !== confirm) {
			setError(t("Passwords do not match"));
			return;
		}

		setLoading(true);

		try {
			if (!register) {
				throw new Error("Registration not available for this auth provider");
			}
			await register(email, password, invite || undefined);
		} catch (err) {
			setError(
				registrationErrorMessage(err instanceof Error ? err.message : "Registration failed", t),
			);
		} finally {
			setLoading(false);
		}
	}

	// While bootstrap is still in flight, render a card-shaped placeholder
	// so the layout doesn't shift and we don't flash the default form before
	// swapping in the mode-specific empty state.
	if (bootstrap === undefined) {
		return (
			<AuthLayout>
				<div
					role="status"
					aria-busy
					aria-label={t("Loading")}
					className="h-[420px] w-full max-w-sm rounded-2xl border border-border bg-card shadow-sm sm:p-8"
				/>
			</AuthLayout>
		);
	}

	// Gate the form when registration is administratively blocked. Only kicks
	// in after bootstrap closes — during bootstrap the operator is allowed
	// through regardless of mode (claim window).
	const gated =
		bootstrap && !bootstrap.bootstrap_pending
			? bootstrap.registration_mode === "closed"
				? "closed"
				: bootstrap.registration_mode === "invite_only" && !invite
					? "need_invite"
					: null
			: null;

	if (gated) {
		return (
			<AuthLayout>
				<section
					className="w-full max-w-sm space-y-4 rounded-2xl border border-border bg-card p-6 shadow-sm sm:p-8"
					role="status"
				>
					<div className="flex flex-col items-center gap-2 text-center">
						<img src="/engram-mark.svg" alt="Engram" className="size-12" />
						<h1 className={heading}>
							{gated === "closed" ? t("Sign-ups are closed") : t("Invite required")}
						</h1>
					</div>
					<p className="text-center text-muted-foreground text-sm">
						{gated === "closed"
							? t(
									"This Engram instance is not accepting new accounts. Contact your admin if you think this is a mistake.",
								)
							: t(
									"Sign-ups on this instance require an invite link. Contact your admin to request one — they can generate one from Settings → Administration.",
								)}
					</p>
					<p className="text-center text-muted-foreground text-sm">
						<Link
							to={authUrlWithReturnTo(ROUTES.SIGN_IN, returnTo)}
							className="font-medium text-primary hover:underline"
						>
							{t("Back to sign in")}
						</Link>
					</p>
				</section>
			</AuthLayout>
		);
	}

	return (
		<AuthLayout>
			<form
				onSubmit={handleSubmit}
				className="w-full max-w-sm space-y-4 rounded-2xl border border-border bg-card p-6 shadow-sm sm:p-8"
			>
				<div className="flex flex-col items-center gap-2 text-center">
					<img src="/engram-mark.svg" alt="Engram" className="size-12" />
					<h1 className={heading}>
						{bootstrap?.bootstrap_pending ? t("Set up your instance") : t("Create your account")}
					</h1>
				</div>

				{Boolean(bootstrap?.bootstrap_pending) && (
					<>
						<aside
							className="rounded-md border border-primary/40 bg-primary/5 px-3 py-2 text-foreground text-sm"
							role="status"
						>
							<p className="font-medium">{t("Welcome — you're setting up this instance.")}</p>
							<p className="mt-1 text-muted-foreground">
								{t(
									"This first account becomes the administrator. After signup, new accounts will need an invite link. Manage members, invites, and registration mode under Settings → Administration.",
								)}
							</p>
						</aside>

						<aside
							className="rounded-md border border-border bg-muted/30 px-3 py-2 text-muted-foreground text-xs"
							role="note"
						>
							<Trans
								text="Engram self-host is in active development — your feedback shapes what ships next. File issues at {repo} or email {email}."
								slots={{
									repo: (
										<a
											href="https://github.com/engram-app/Engram/issues"
											target="_blank"
											rel="noreferrer noopener"
											className="font-medium text-primary hover:underline"
										>
											github.com/engram-app/Engram
										</a>
									),
									email: (
										<a
											href="mailto:support@engram.page"
											className="font-medium text-primary hover:underline"
										>
											support@engram.page
										</a>
									),
								}}
							/>
						</aside>
					</>
				)}

				{invite && invitePreview ? (
					invitePreview.valid ? (
						<p className="rounded-md border border-primary/40 bg-primary/5 px-3 py-2 text-foreground text-sm">
							{invitePreview.label
								? t("You've been invited ({label}) — finish below to join.", {
										label: invitePreview.label,
									})
								: t("You've been invited — finish below to join.")}
						</p>
					) : (
						<p
							role="alert"
							className="rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2 text-foreground text-sm"
						>
							{t("This invite link is invalid, expired, or already used.")}
						</p>
					)
				) : null}

				{Boolean(error) && (
					<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
						{error}
					</p>
				)}

				<label className="block">
					<span className="font-medium text-foreground text-sm">{t("Email")}</span>
					<input
						type="email"
						required
						value={email}
						onChange={(e) => setEmail(e.target.value)}
						className={cn("mt-1 block", fieldInput)}
					/>
				</label>

				<label className="block">
					<span className="font-medium text-foreground text-sm">{t("Password")}</span>
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
					<span className="font-medium text-foreground text-sm">{t("Confirm password")}</span>
					<input
						type="password"
						required
						value={confirm}
						onChange={(e) => setConfirm(e.target.value)}
						className={cn("mt-1 block", fieldInput)}
					/>
				</label>

				<Button type="submit" disabled={loading} className="w-full">
					{loading ? t("Creating account…") : t("Create account")}
				</Button>

				<p className="text-center text-muted-foreground text-sm">
					<Trans
						text="Already have an account? {signin}"
						slots={{
							signin: (
								<Link
									to={authUrlWithReturnTo(ROUTES.SIGN_IN, returnTo)}
									className="font-medium text-primary hover:underline"
								>
									{t("Sign in")}
								</Link>
							),
						}}
					/>
				</p>
			</form>
		</AuthLayout>
	);
}
