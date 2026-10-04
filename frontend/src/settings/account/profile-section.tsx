import { useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useRef } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { clerkErrorMessage } from "./clerk-errors";
import { SettingsSectionCard } from "./section-card";

export function ProfileSection() {
	const { t } = useT();
	const { user, isLoaded } = useUser();
	const fileInputRef = useRef<HTMLInputElement>(null);
	// Changing the avatar is reverification-protected — raw calls return 403.
	const setProfileImage = useReverification((file: File) => user!.setProfileImage({ file }));

	if (!(isLoaded && user)) {
		return null;
	}

	async function onImage(e: React.ChangeEvent<HTMLInputElement>) {
		const file = e.target.files?.[0];
		if (!file) {
			return;
		}
		try {
			await setProfileImage(file);
			toast.success(t("Profile image updated"));
		} catch (err) {
			if (isReverificationCancelledError(err)) {
				return;
			}
			toast.error(clerkErrorMessage(err, t("Could not update image")));
		} finally {
			// Reset so picking the same file again still fires onChange.
			e.target.value = "";
		}
	}

	return (
		<SettingsSectionCard title={t("Profile photo")} description={t("Your avatar.")}>
			<div className="flex items-center gap-4">
				<img
					src={user.imageUrl}
					alt=""
					className="size-14 rounded-full border border-border object-cover"
				/>
				<div>
					<input
						ref={fileInputRef}
						aria-label={t("Profile image")}
						type="file"
						accept="image/*"
						onChange={onImage}
						className="sr-only"
					/>
					<Button
						type="button"
						variant="outline"
						size="sm"
						onClick={() => fileInputRef.current?.click()}
					>
						{t("Change photo")}
					</Button>
					<p className="mt-1 text-muted-foreground text-xs">{t("JPG, PNG or GIF.")}</p>
				</div>
			</div>
		</SettingsSectionCard>
	);
}
