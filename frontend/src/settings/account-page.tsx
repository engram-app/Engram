import { AppearanceSection } from "./account/appearance-section";
import { ConnectedAccountsSection } from "./account/connected-accounts-section";
import { DangerZoneSection } from "./account/danger-zone-section";
import { EmailSection } from "./account/email-section";
import { PasswordSection } from "./account/password-section";
import { ProfileSection } from "./account/profile-section";
import { SessionsSection } from "./account/sessions-section";

// OAuth providers enabled on this Clerk instance. Confirm against the instance
// before adjusting (see note below).
const OAUTH_PROVIDERS = ["oauth_apple", "oauth_google", "oauth_github"] as const;

export default function AccountPage() {
	return (
		<article className="space-y-6">
			<header>
				<h1 className="font-semibold text-foreground text-xl">Account</h1>
				<p className="mt-1 text-muted-foreground text-sm">
					Manage your profile, security, and active sessions.
				</p>
			</header>
			<ProfileSection />
			<AppearanceSection />
			<EmailSection />
			<PasswordSection />
			<ConnectedAccountsSection providers={[...OAUTH_PROVIDERS]} />
			<SessionsSection />
			<DangerZoneSection />
		</article>
	);
}
