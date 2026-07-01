import { type FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import { destructiveAlert, fieldInput, heading } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { getApiBase, joinApiUrl } from "../api/base";
import { ROUTES } from "../routes";
import AuthLayout from "./auth-layout";
import { useAuthAdapter } from "./use-auth-adapter";
import { useBootstrap } from "./use-bootstrap";

interface InvitePreview {
	valid: boolean;
	label?: string | null;
}

export default function LocalSignUp() {
	const { register, isSignedIn } = useAuthAdapter();
	const navigate = useNavigate();
	const [searchParams] = useSearchParams();
	const invite = searchParams.get("invite") ?? "";
	const bootstrap = useBootstrap();
	const [invitePreview, setInvitePreview] = useState<InvitePreview | null>(null);
	const [email, setEmail] = useState("");
	const [password, setPassword] = useState("");
	const [confirm, setConfirm] = useState("");
	const [error, setError] = useState("");
	const [loading, setLoading] = useState(false);

	// Navigate after auth state propagates (React 18 batching)
	useEffect(() => {
		if (isSignedIn) {
			navigate(ROUTES.HOME, { replace: true });
		}
	}, [isSignedIn, navigate]);

	// Preview the invite (non-enumerating: bad/expired/revoked → {valid:false}).
	useEffect(() => {
		if (!invite) {
			setInvitePreview(null);
			return;
		}
		fetch(joinApiUrl(getApiBase(), `/api/auth/invite/${encodeURIComponent(invite)}`))
			.then((r) => r.json())
			.then((p: InvitePreview) => setInvitePreview(p))
			.catch(() => setInvitePreview({ valid: false }));
	}, [invite]);

	async function handleSubmit(e: FormEvent) {
		e.preventDefault();
		setError("");

		if (password !== confirm) {
			setError("Passwords do not match");
			return;
		}

		setLoading(true);

		try {
			if (!register) {
				throw new Error("Registration not available for this auth provider");
			}
			await register(email, password, invite || undefined);
		} catch (err) {
			setError(err instanceof Error ? err.message : "Registration failed");
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
					aria-busy
					aria-label="Loading"
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
							{gated === "closed" ? "Sign-ups are closed" : "Invite required"}
						</h1>
					</div>
					<p className="text-center text-muted-foreground text-sm">
						{gated === "closed"
							? "This Engram instance is not accepting new accounts. Contact your admin if you think this is a mistake."
							: "Sign-ups on this instance require an invite link. Contact your admin to request one — they can generate one from Settings → Administration."}
					</p>
					<p className="text-center text-muted-foreground text-sm">
						<Link to={ROUTES.SIGN_IN} className="font-medium text-primary hover:underline">
							Back to sign in
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
						{bootstrap?.bootstrap_pending ? "Set up your instance" : "Create your account"}
					</h1>
				</div>

				{bootstrap?.bootstrap_pending && (
					<>
						<aside
							className="rounded-md border border-primary/40 bg-primary/5 px-3 py-2 text-foreground text-sm"
							role="status"
						>
							<p className="font-medium">Welcome — you're setting up this instance.</p>
							<p className="mt-1 text-muted-foreground">
								This first account becomes the administrator. After signup, new accounts will need
								an invite link. Manage members, invites, and registration mode under Settings →
								Administration.
							</p>
						</aside>

						<aside
							className="rounded-md border border-border bg-muted/30 px-3 py-2 text-muted-foreground text-xs"
							role="note"
						>
							Engram self-host is in active development — your feedback shapes what ships next. File
							issues at{" "}
							<a
								href="https://github.com/engram-app/Engram/issues"
								target="_blank"
								rel="noreferrer noopener"
								className="font-medium text-primary hover:underline"
							>
								github.com/engram-app/Engram
							</a>{" "}
							or email{" "}
							<a
								href="mailto:support@engram.page"
								className="font-medium text-primary hover:underline"
							>
								support@engram.page
							</a>
							.
						</aside>
					</>
				)}

				{invite &&
					invitePreview &&
					(invitePreview.valid ? (
						<p className="rounded-md border border-primary/40 bg-primary/5 px-3 py-2 text-foreground text-sm">
							You've been invited{invitePreview.label ? ` (${invitePreview.label})` : ""} — finish
							below to join.
						</p>
					) : (
						<p
							role="alert"
							className="rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2 text-foreground text-sm"
						>
							This invite link is invalid, expired, or already used.
						</p>
					))}

				{error && (
					<p role="alert" className={cn(destructiveAlert, "p-3 text-foreground")}>
						{error}
					</p>
				)}

				<label className="block">
					<span className="font-medium text-foreground text-sm">Email</span>
					<input
						type="email"
						required
						value={email}
						onChange={(e) => setEmail(e.target.value)}
						className={cn("mt-1 block", fieldInput)}
					/>
				</label>

				<label className="block">
					<span className="font-medium text-foreground text-sm">Password</span>
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
					{loading ? "Creating account…" : "Create account"}
				</Button>

				<p className="text-center text-muted-foreground text-sm">
					Already have an account?{" "}
					<Link to={ROUTES.SIGN_IN} className="font-medium text-primary hover:underline">
						Sign in
					</Link>
				</p>
			</form>
		</AuthLayout>
	);
}
