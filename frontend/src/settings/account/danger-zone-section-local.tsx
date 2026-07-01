import { useState } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
	Dialog,
	DialogClose,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
	DialogTrigger,
} from "@/components/ui/dialog";
import { useDeleteSelf } from "../../api/queries";
import { useAuthAdapter } from "../../auth/use-auth-adapter";
import { ROUTES } from "../../routes";
import { SettingsSectionCard } from "./section-card";

const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

export function DangerZoneSectionLocal() {
	const { logout } = useAuthAdapter();
	const navigate = useNavigate();
	const deleter = useDeleteSelf();
	const [open, setOpen] = useState(false);
	const [password, setPassword] = useState("");
	const [confirmed, setConfirmed] = useState(false);
	const [error, setError] = useState<string | null>(null);

	function reset() {
		setPassword("");
		setConfirmed(false);
		setError(null);
	}

	async function onDelete() {
		setError(null);
		try {
			await deleter.mutateAsync({ password });
			toast.success("Account deleted");
			await logout();
			navigate(ROUTES.SIGN_IN);
		} catch (err) {
			const msg = err instanceof Error ? err.message : "Delete failed";
			if (msg.includes("last_admin")) {
				setError(
					"You're the only admin on this instance. Promote another user to admin first, then try again.",
				);
			} else if (msg.includes("invalid_password")) {
				setError("Incorrect password.");
			} else {
				setError(msg);
			}
		}
	}

	return (
		<SettingsSectionCard
			title="Danger zone"
			description="Permanent actions. Deleting your account signs you out and blocks future sign-ins to this user."
		>
			<Dialog
				open={open}
				onOpenChange={(v) => {
					setOpen(v);
					if (!v) {
						reset();
					}
				}}
			>
				<DialogTrigger asChild>
					<Button type="button" variant="destructive" size="sm">
						Delete account
					</Button>
				</DialogTrigger>
				<DialogContent>
					<DialogHeader>
						<DialogTitle>Delete your account?</DialogTitle>
						<DialogDescription>
							This soft-deletes your user. You won&apos;t be able to sign back in. An admin can
							purge your vault data later.
						</DialogDescription>
					</DialogHeader>
					<fieldset className="space-y-3">
						<label className="block font-medium text-foreground text-sm">
							Password
							<input
								className={inputClass}
								type="password"
								autoComplete="current-password"
								value={password}
								onChange={(e) => setPassword(e.target.value)}
							/>
						</label>
						<label className="flex items-center gap-2 text-sm">
							<Checkbox
								checked={confirmed}
								onCheckedChange={(v) => setConfirmed(v === true)}
								aria-label="I understand this is irreversible"
							/>
							I understand this is irreversible
						</label>
						{Boolean(error) && <p className="text-destructive text-sm">{error}</p>}
					</fieldset>
					<DialogFooter>
						<DialogClose asChild>
							<Button type="button" variant="outline" size="sm">
								Cancel
							</Button>
						</DialogClose>
						<Button
							type="button"
							variant="destructive"
							size="sm"
							disabled={!confirmed || password.length === 0 || deleter.isPending}
							onClick={onDelete}
						>
							Delete
						</Button>
					</DialogFooter>
				</DialogContent>
			</Dialog>
		</SettingsSectionCard>
	);
}
