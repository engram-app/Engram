import { useEffect, useState } from "react";
import { ApiError } from "../api/client";
import { useAcceptTerms, useOnboardingStatus } from "../api/queries";
import { type LegalDocKind, loadVersion, renderableVersion, sha256Hex } from "./load";

interface Loaded {
	version: string;
	text: string | undefined;
}

// The text of `version`, once its chunk has loaded. `text` is undefined if the
// load failed (logged): the caller reports it unavailable rather than crash.
function useLegalText(doc: LegalDocKind, version: string | undefined): Loaded | undefined {
	const [loaded, setLoaded] = useState<Loaded>();
	useEffect(() => {
		if (!version) {
			return;
		}
		let live = true;
		loadVersion(doc, version).then(
			(text) => {
				if (live) {
					setLoaded({ version, text });
				}
			},
			(err: unknown) => {
				console.error(err);
				if (live) {
					setLoaded({ version, text: undefined });
				}
			},
		);
		return () => {
			live = false;
		};
	}, [doc, version]);
	return loaded?.version === version ? loaded : undefined;
}

// What to accept for one document: exactly `shown` when the caller displayed a
// specific version (it must be bundled), else the newest bundled version not
// newer than the backend's current one. A bundle built before a publish lacks
// the newest text; the backend accepts an older known version at or above the
// required floor, so signup does not pause on a deploy skew.
function target(doc: LegalDocKind, shown: string | undefined, current: string | undefined) {
	if (shown) {
		return renderableVersion(doc, shown) === shown ? shown : undefined;
	}
	return current ? renderableVersion(doc, current) : undefined;
}

// Records acceptance of the Terms and Privacy Policy, pinned by the hash of
// the exact text this build renders. Shared by the agreement page and the
// notice banner's dismiss, which passes the versions it showed.
export function useAcceptAgreements(shown: Partial<Record<LegalDocKind, string>> = {}) {
	const { data } = useOnboardingStatus();
	const { mutateAsync, isPending } = useAcceptTerms();
	const [refused, setRefused] = useState(false);
	const wantTos = shown.terms ?? data?.current_tos_version;
	const wantPrivacy = shown.privacy ?? data?.current_privacy_version;
	const tosVersion = target("terms", shown.terms, data?.current_tos_version);
	const privacyVersion = target("privacy", shown.privacy, data?.current_privacy_version);
	const tos = useLegalText("terms", tosVersion);
	const privacy = useLegalText("privacy", privacyVersion);
	const tosText = tos?.text;
	const privacyText = privacy?.text;

	const missing = (want: string | undefined, version: string | undefined, got?: Loaded) =>
		Boolean(want && (!version || (got && got.text === undefined)));
	const unavailable =
		refused || missing(wantTos, tosVersion, tos) || missing(wantPrivacy, privacyVersion, privacy);
	const ready = !unavailable && Boolean(tosText && privacyText);

	async function accept(): Promise<boolean> {
		if (!(tosVersion && privacyVersion && tosText && privacyText) || refused) {
			return false;
		}
		const [tos_hash, privacy_hash] = await Promise.all([
			sha256Hex(tosText),
			sha256Hex(privacyText),
		]);
		try {
			await mutateAsync({
				tos_version: tosVersion,
				tos_hash,
				privacy_version: privacyVersion,
				privacy_hash,
			});
		} catch (err) {
			// 409: the text this bundle can render is below the required floor
			// (or drifted). Nothing this bundle shows can be accepted; say so.
			if (err instanceof ApiError && err.status === 409) {
				setRefused(true);
				return false;
			}
			throw err;
		}
		return true;
	}

	return { accept, isPending, ready, unavailable, tosText, privacyText };
}
