import { useClerk, useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ROUTES } from "@/routes";

const CONFIRM = "delete my account";
const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

export function DangerZoneSection() {
	const { user, isLoaded } = useUser();
	const clerk = useClerk();
	const [phrase, setPhrase] = useState("");
	const remove = useReverification(() => user!.delete());

	if (!(isLoaded && user)) {
		return null;
	}

	async function onDelete() {
		try {
			await remove();
			await clerk.signOut({ redirectUrl: ROUTES.SIGN_IN });
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error("Could not delete account");
		}
	}

	return (
		<section className="rounded-lg border border-destructive/40 bg-destructive/5 p-4 sm:p-6">
			<header className="mb-4">
				<h2 className="font-semibold text-base text-destructive">Danger zone</h2>
				<p className="mt-1 text-muted-foreground text-sm">
					Permanently delete your account and all associated data. This cannot be undone.
				</p>
			</header>
			<form
				onSubmit={(e) => {
					e.preventDefault();
					onDelete();
				}}
			>
				<label className="block font-medium text-foreground text-sm">
					Type "{CONFIRM}" to confirm
					<input
						className={inputClass}
						value={phrase}
						onChange={(e) => setPhrase(e.target.value)}
					/>
				</label>
				<Button className="mt-4" type="submit" variant="destructive" disabled={phrase !== CONFIRM}>
					Delete my account
				</Button>
			</form>
		</section>
	);
}
