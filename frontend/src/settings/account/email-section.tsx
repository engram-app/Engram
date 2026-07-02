import { useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { clerkErrorMessage } from "./clerk-errors";
import { SettingsSectionCard } from "./section-card";

const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

// Clerk can't rename an email address, so "change my primary email" is really:
// add (or reuse) the new address → verify it → set it primary → delete the old
// primary. We present that as a single "update email" flow that ends with one
// address on the account.
export function EmailSection() {
	const { user, isLoaded } = useUser();
	const [newEmail, setNewEmail] = useState("");
	const [code, setCode] = useState("");
	// The address awaiting an email code, held between "send code" and "verify".
	const [pending, setPending] = useState<{
		id: string;
		attemptVerification: (p: { code: string }) => Promise<unknown>;
	} | null>(null);

	// All three calls are reverification-protected — raw calls return 403.
	const createEmailAddress = useReverification((address: string) =>
		user!.createEmailAddress({ email: address }),
	);
	const setPrimary = useReverification((id: string) => user!.update({ primaryEmailAddressId: id }));
	const removeEmail = useReverification((destroy: () => Promise<unknown>) => destroy());

	if (!(isLoaded && user)) {
		return null;
	}

	const primaryId = user.primaryEmailAddressId;
	const currentEmail = user.emailAddresses.find((e) => e.id === primaryId)?.emailAddress ?? "";

	// Promote `newId` to primary and delete the previous primary so exactly one
	// address remains. `previousPrimaryId` is captured by the caller before the
	// promotion so the cleanup targets the right address.
	async function promoteAndCleanUp(newId: string, previousPrimaryId: string | null) {
		await setPrimary(newId);
		const old =
			previousPrimaryId && previousPrimaryId !== newId
				? user!.emailAddresses.find((e) => e.id === previousPrimaryId)
				: undefined;
		// Best-effort: the primary has already changed, so removing the old
		// address is secondary. A failure here must NOT be reported as if the
		// whole email change failed (that left a leftover address + a misleading
		// error). Worst case the old address lingers, harmlessly.
		if (old) {
			try {
				await removeEmail(() => old.destroy());
			} catch (e) {
				if (!isReverificationCancelledError(e)) {
					console.error("primary email changed but old address cleanup failed", e);
				}
			}
		}
		await user!.reload();
		setPending(null);
		setNewEmail("");
		setCode("");
		toast.success("Email updated");
	}

	async function startChange() {
		const target = newEmail.trim();
		if (!target) {
			return;
		}
		if (target.toLowerCase() === currentEmail.toLowerCase()) {
			toast.error("That's already your email");
			return;
		}
		try {
			// Reuse an address already on the account (e.g. a leftover secondary)
			// instead of re-adding it, which Clerk would reject as a duplicate.
			const existing = user!.emailAddresses.find(
				(e) => e.emailAddress.toLowerCase() === target.toLowerCase(),
			);
			if (existing) {
				if (existing.verification?.status === "verified") {
					await promoteAndCleanUp(existing.id, primaryId);
					return;
				}
				await existing.prepareVerification({ strategy: "email_code" });
				setPending({
					id: existing.id,
					attemptVerification: (p) => existing.attemptVerification(p),
				});
				toast.success("Verification code sent");
				return;
			}

			const created = await createEmailAddress(target);
			await created.prepareVerification({ strategy: "email_code" });
			setPending({
				id: created.id,
				attemptVerification: (p) => created.attemptVerification(p),
			});
			toast.success("Verification code sent");
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error(clerkErrorMessage(e, "Could not update email"));
		}
	}

	async function verify() {
		if (!pending) {
			return;
		}
		// Verify the code first — only a failure HERE means a bad code.
		try {
			await pending.attemptVerification({ code });
		} catch {
			toast.error("Invalid code");
			return;
		}
		// Code accepted; promotion is a separate step so its errors aren't
		// misreported as "Invalid code".
		try {
			await promoteAndCleanUp(pending.id, primaryId);
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error(clerkErrorMessage(e, "Could not update email"));
		}
	}

	return (
		<SettingsSectionCard title="Email" description="Change the email you use to sign in.">
			<div className="flex items-center justify-between gap-3 rounded-md border border-border bg-muted/40 px-3 py-2">
				<span className="min-w-0 truncate font-mono text-foreground text-sm">{currentEmail}</span>
				<span className="shrink-0 rounded bg-muted px-1.5 py-0.5 text-muted-foreground text-xs">
					Primary
				</span>
			</div>

			{pending ? (
				<form
					className="mt-4"
					onSubmit={(ev) => {
						ev.preventDefault();
						verify();
					}}
				>
					<label className="block font-medium text-foreground text-sm">
						Verification code
						<input
							className={inputClass}
							value={code}
							onChange={(ev) => setCode(ev.target.value)}
						/>
					</label>
					<p className="mt-1 text-muted-foreground text-xs">
						Enter the code we sent to confirm your new email.
					</p>
					<Button className="mt-2" type="submit">
						Verify
					</Button>
				</form>
			) : (
				<form
					className="mt-4 flex items-end gap-2"
					onSubmit={(ev) => {
						ev.preventDefault();
						startChange();
					}}
				>
					<label className="block flex-1 font-medium text-foreground text-sm">
						New email
						<input
							className={inputClass}
							type="email"
							value={newEmail}
							onChange={(ev) => setNewEmail(ev.target.value)}
						/>
					</label>
					<Button type="submit">Update email</Button>
				</form>
			)}
		</SettingsSectionCard>
	);
}
