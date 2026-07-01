/**
 * Live status indicator for the plugin-sync handshake. Used by both the
 * onboarding wizard's Obsidian branch and the `/link` success step, which
 * each spend time waiting on the same Phoenix `vault_populated` broadcast.
 *
 * Visual contract: dashed border, muted background, pulsing primary dot,
 * one line of muted copy. Centralized so the two surfaces can't drift.
 */
interface SyncStatusPillProps {
	message: string;
}

export function SyncStatusPill({ message }: SyncStatusPillProps) {
	return (
		<p
			role="status"
			aria-live="polite"
			className="flex items-center gap-2 rounded-md border border-dashed border-border bg-muted/40 px-3 py-2 text-sm text-muted-foreground"
		>
			<span
				aria-hidden
				className="inline-block size-2 shrink-0 animate-pulse rounded-full bg-primary"
			/>
			<span>{message}</span>
		</p>
	);
}
