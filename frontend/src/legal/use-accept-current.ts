import { useAcceptTerms, useOnboardingStatus } from "../api/queries";
import { loadVersion, sha256Hex } from "./load";

// loadVersion throws if the backend reports a version this build hasn't vendored
// (e.g. backend deployed ahead of an app sync). Don't crash over it: log loudly
// and report it unavailable, so a user can never accept text we can't display.
function tryLoadVersion(doc: "terms" | "privacy", version: string | undefined): string | undefined {
	if (!version) {
		return;
	}
	try {
		return loadVersion(doc, version);
	} catch (err) {
		console.error(err);
	}
}

// Records acceptance of the current Terms and Privacy Policy, pinned by the
// hash of the exact text this build renders. Shared by the agreement page and
// the notice banner's dismiss.
export function useAcceptCurrentAgreements() {
	const { data } = useOnboardingStatus();
	const { mutateAsync, isPending } = useAcceptTerms();
	const tosVersion = data?.current_tos_version;
	const privacyVersion = data?.current_privacy_version;
	const tosText = tryLoadVersion("terms", tosVersion);
	const privacyText = tryLoadVersion("privacy", privacyVersion);

	const unavailable = Boolean((tosVersion && !tosText) || (privacyVersion && !privacyText));
	const ready = Boolean(tosVersion && privacyVersion && tosText && privacyText);

	async function accept(): Promise<boolean> {
		if (!(tosVersion && privacyVersion && tosText && privacyText)) {
			return false;
		}
		const [tos_hash, privacy_hash] = await Promise.all([
			sha256Hex(tosText),
			sha256Hex(privacyText),
		]);
		await mutateAsync({
			tos_version: tosVersion,
			tos_hash,
			privacy_version: privacyVersion,
			privacy_hash,
		});
		return true;
	}

	return { accept, isPending, ready, unavailable, tosText };
}
