import { AppearanceSection } from "./account/appearance-section";
import { DangerZoneSectionLocal } from "./account/danger-zone-section-local";
import { EmailReadonlySection } from "./account/email-readonly-section";
import { LanguageSection } from "./account/language-section";
import { PasswordSectionLocal } from "./account/password-section-local";
import { ProfileSectionLocal } from "./account/profile-section-local";

export default function AccountPageLocal() {
	return (
		<article className="space-y-6">
			<header>
				<h1 className="font-semibold text-foreground text-xl">Account</h1>
				<p className="mt-1 text-muted-foreground text-sm">
					Manage your profile, password, and account.
				</p>
			</header>
			<ProfileSectionLocal />
			<AppearanceSection />
			<LanguageSection />
			<EmailReadonlySection />
			<PasswordSectionLocal />
			<DangerZoneSectionLocal />
		</article>
	);
}
