import { useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import type { OAuthStrategy } from "@clerk/shared/types";
import type { ReactNode } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { SettingsSectionCard } from "./section-card";

const GitHubIcon = () => (
	<svg viewBox="0 0 16 16" aria-hidden="true" className="size-4 fill-current">
		<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
	</svg>
);

const GoogleIcon = () => (
	<svg viewBox="0 0 24 24" aria-hidden="true" className="size-4">
		<path
			fill="#4285F4"
			d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.76h3.57c2.08-1.92 3.27-4.74 3.27-8.09Z"
		/>
		<path
			fill="#34A853"
			d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.76c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84A11 11 0 0 0 12 23Z"
		/>
		<path
			fill="#FBBC05"
			d="M5.84 14.11a6.6 6.6 0 0 1 0-4.22V7.05H2.18a11 11 0 0 0 0 9.9l3.66-2.84Z"
		/>
		<path
			fill="#EA4335"
			d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1A11 11 0 0 0 2.18 7.05l3.66 2.84C6.71 7.3 9.14 5.38 12 5.38Z"
		/>
	</svg>
);

const DiscordIcon = () => (
	<svg viewBox="0 0 16 16" aria-hidden="true" className="size-4 fill-current">
		<path d="M13.545 2.907a13.2 13.2 0 0 0-3.257-1.011.05.05 0 0 0-.052.025c-.141.25-.297.577-.406.833a12.2 12.2 0 0 0-3.658 0 8 8 0 0 0-.412-.833.05.05 0 0 0-.052-.025c-1.125.194-2.22.534-3.257 1.011a.04.04 0 0 0-.021.018C.356 6.024-.213 9.047.066 12.032q.003.022.021.036a13.3 13.3 0 0 0 3.995 2.02.05.05 0 0 0 .056-.019q.463-.63.818-1.329a.05.05 0 0 0-.01-.059l-.018-.011a9 9 0 0 1-1.248-.595.05.05 0 0 1-.02-.066l.015-.019q.126-.093.246-.192a.05.05 0 0 1 .051-.007c2.619 1.196 5.454 1.196 8.041 0a.05.05 0 0 1 .053.007q.121.099.245.192a.05.05 0 0 1-.004.085 8 8 0 0 1-1.249.594.05.05 0 0 0-.03.03.05.05 0 0 0 .003.041q.36.697.817 1.329a.05.05 0 0 0 .056.019 13.2 13.2 0 0 0 4.001-2.02.05.05 0 0 0 .021-.037c.334-3.451-.559-6.449-2.366-9.106a.03.03 0 0 0-.02-.019m-8.198 7.307c-.789 0-1.438-.724-1.438-1.612s.637-1.613 1.438-1.613c.807 0 1.45.73 1.438 1.613 0 .888-.637 1.612-1.438 1.612m5.316 0c-.788 0-1.438-.724-1.438-1.612s.637-1.613 1.438-1.613c.807 0 1.451.73 1.438 1.613 0 .888-.631 1.612-1.438 1.612" />
	</svg>
);

const PROVIDERS: Record<string, { name: string; icon: ReactNode }> = {
	github: { name: "GitHub", icon: <GitHubIcon /> },
	google: { name: "Google", icon: <GoogleIcon /> },
	discord: { name: "Discord", icon: <DiscordIcon /> },
};

function meta(raw: string) {
	const key = raw.replace(/^oauth_/u, "");
	return PROVIDERS[key] ?? { name: key.replace(/^\w/u, (c) => c.toUpperCase()), icon: null };
}

export function ConnectedAccountsSection({ providers }: { providers: OAuthStrategy[] }) {
	const { user, isLoaded } = useUser();
	const disconnect = useReverification((destroy: () => Promise<unknown>) => destroy());
	// Adding a connection is a reverification-protected action — calling it
	// unwrapped returns a 403 from Clerk. useReverification surfaces the re-auth
	// modal and retries, matching Clerk's documented custom-flow.
	const createExternalAccount = useReverification(
		(params: Parameters<NonNullable<typeof user>["createExternalAccount"]>[0]) =>
			user!.createExternalAccount(params),
	);

	if (!(isLoaded && user)) {
		return null;
	}
	// Only accounts Clerk has actually verified count as connected. An abandoned
	// or failed OAuth link leaves an `unverified` externalAccount record behind;
	// treating those as connected made the button flip to "connected" even when
	// the handshake never completed. Filter them out so the provider stays
	// offered and the user can retry.
	const verifiedAccounts = user.externalAccounts.filter(
		(a) => a.verification?.status === "verified",
	);
	const connected = new Set(verifiedAccounts.map((a) => `oauth_${a.provider}`));

	async function onDisconnect(destroy: () => Promise<unknown>) {
		try {
			await disconnect(destroy);
			await user!.reload();
			toast.success("Account disconnected");
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error("Could not disconnect account");
		}
	}

	async function connect(strategy: OAuthStrategy) {
		try {
			const acct = await createExternalAccount({
				strategy,
				redirectUrl: `${window.location.origin}/settings/account`,
			});
			const url = acct?.verification?.externalVerificationRedirectURL;
			if (url) {
				window.location.href = url.toString();
			}
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error("Could not start connection");
		}
	}

	const available = providers.filter((p) => !connected.has(p));

	return (
		<SettingsSectionCard
			title="Connected accounts"
			description="Link third-party sign-in providers."
		>
			{verifiedAccounts.length > 0 && (
				<ul className="divide-y divide-border">
					{verifiedAccounts.map((a) => {
						const { name, icon } = meta(a.provider);
						const secondary = a.emailAddress || a.username || "Connected";
						return (
							<li
								key={a.id}
								className="flex items-center justify-between gap-3 py-3 text-sm first:pt-0 last:pb-0"
							>
								<span className="flex min-w-0 items-center gap-3">
									<span className="flex size-9 shrink-0 items-center justify-center rounded-md border border-border bg-muted text-foreground">
										{icon}
									</span>
									<span className="flex min-w-0 flex-col">
										<span className="font-medium text-foreground">{name}</span>
										<span className="truncate text-muted-foreground text-xs">{secondary}</span>
									</span>
								</span>
								<Button
									variant="destructive"
									size="sm"
									className="shrink-0"
									aria-label={`Disconnect ${name}`}
									onClick={() => onDisconnect(() => a.destroy())}
								>
									Disconnect
								</Button>
							</li>
						);
					})}
				</ul>
			)}

			{available.length > 0 && (
				<div className="mt-4 flex flex-wrap gap-2">
					{available.map((p) => {
						const { name, icon } = meta(p);
						return (
							<Button
								key={p}
								variant="outline"
								size="sm"
								className="gap-2"
								onClick={() => connect(p)}
							>
								{icon}
								Connect {name}
							</Button>
						);
					})}
				</div>
			)}
		</SettingsSectionCard>
	);
}
