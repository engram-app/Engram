import { useState } from "react";
import { useUser, useReverification } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { clerkErrorMessage } from "./clerk-errors";
import { SettingsSectionCard } from "./section-card";

const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

export function EmailSection() {
	const { user, isLoaded } = useUser();
	const [email, setEmail] = useState("");
	const [pending, setPending] = useState<{
		attemptVerification: (p: { code: string }) => Promise<unknown>;
	} | null>(null);
	const [code, setCode] = useState("");
	const removeEmail = useReverification((destroy: () => Promise<unknown>) => destroy());
	const setPrimary = useReverification((id: string) => user!.update({ primaryEmailAddressId: id }));
	// Adding an email is reverification-protected — raw calls return 403.
	const createEmailAddress = useReverification((address: string) =>
		user!.createEmailAddress({ email: address }),
	);

	if (!isLoaded || !user) return null;

	async function add() {
		try {
			const created = await createEmailAddress(email);
			await created.prepareVerification({ strategy: "email_code" });
			setPending(created);
			toast.success("Verification code sent");
		} catch (e) {
			if (isReverificationCancelledError(e)) return;
			toast.error(clerkErrorMessage(e, "Could not add email"));
		}
	}

	async function verify() {
		try {
			await pending!.attemptVerification({ code });
			setPending(null);
			setEmail("");
			setCode("");
			toast.success("Email verified");
		} catch {
			toast.error("Invalid code");
		}
	}

	async function makePrimary(id: string) {
		try {
			await setPrimary(id);
			await user!.reload();
			toast.success("Primary email updated");
		} catch (e) {
			if (isReverificationCancelledError(e)) return;
			toast.error("Could not set primary email");
		}
	}

	async function remove(destroy: () => Promise<unknown>) {
		try {
			await removeEmail(destroy);
			await user!.reload();
			toast.success("Email removed");
		} catch (e) {
			if (isReverificationCancelledError(e)) return;
			toast.error("Could not remove email");
		}
	}

	const sortedEmails = [...user.emailAddresses].sort((a, b) => {
		if (a.id === user!.primaryEmailAddressId) return -1;
		if (b.id === user!.primaryEmailAddressId) return 1;
		return 0;
	});

	return (
		<SettingsSectionCard
			title="Email addresses"
			description="Add, verify, or remove email addresses."
		>
			<ul className="divide-y divide-border">
				{sortedEmails.map((e) => (
					<li
						key={e.id}
						className="flex flex-col gap-2 py-3 text-sm first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between"
					>
						<span className="flex min-w-0 items-center gap-2 text-foreground">
							<span className="truncate">{e.emailAddress}</span>
							{e.id === user.primaryEmailAddressId && (
								<span className="shrink-0 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
									Primary
								</span>
							)}
						</span>
						<span className="flex shrink-0 gap-2">
							{e.id !== user.primaryEmailAddressId && (
								<Button variant="outline" size="sm" onClick={() => makePrimary(e.id)}>
									Make primary
								</Button>
							)}
							<Button
								variant="destructive"
								size="sm"
								disabled={user.emailAddresses.length <= 1}
								title={
									user.emailAddresses.length <= 1
										? "You must keep at least one email address"
										: undefined
								}
								aria-label={`Remove ${e.emailAddress}`}
								onClick={() => remove(() => e.destroy())}
							>
								Remove
							</Button>
						</span>
					</li>
				))}
			</ul>

			{pending ? (
				<form
					className="mt-4"
					onSubmit={(ev) => {
						ev.preventDefault();
						verify();
					}}
				>
					<label className="block text-sm font-medium text-foreground">
						Verification code
						<input
							className={inputClass}
							value={code}
							onChange={(ev) => setCode(ev.target.value)}
						/>
					</label>
					<Button className="mt-2" type="submit">
						Verify
					</Button>
				</form>
			) : (
				<form
					className="mt-4 flex items-end gap-2"
					onSubmit={(ev) => {
						ev.preventDefault();
						add();
					}}
				>
					<label className="flex-1 block text-sm font-medium text-foreground">
						Add email
						<input
							className={inputClass}
							type="email"
							value={email}
							onChange={(ev) => setEmail(ev.target.value)}
						/>
					</label>
					<Button type="submit">Add</Button>
				</form>
			)}
		</SettingsSectionCard>
	);
}
