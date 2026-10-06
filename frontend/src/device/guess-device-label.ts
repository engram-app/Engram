// Client Hints (Chromium only). `model` is only populated on Android; desktop
// Chromium gives a platform but no model; Safari and Firefox expose neither.
interface UserAgentData {
	platform?: string;
	mobile?: boolean;
	getHighEntropyValues?: (hints: string[]) => Promise<{ model?: string }>;
}

interface BrowserInfo {
	userAgent: string;
	maxTouchPoints?: number;
	userAgentData?: UserAgentData;
}

// Android WebView and Chrome reduce the model to a bare "K" (UA reduction),
// so a one-letter token is not a model name.
const ANDROID_MODEL = /Android[^;)]*;\s*(?<model>[^;)]+?)(?:\s+Build\/[^;)]*)?[;)]/iu;

function isModelName(model: string | undefined): model is string {
	return Boolean(model) && (model?.length ?? 0) > 1 && !/^(?:wv|mobile)$/iu.test(model ?? "");
}

// A suggested connection name for the device this browser is on. iOS never
// reports a model, so an iPhone is just "iPhone"; only Android sometimes does.
export async function guessDeviceLabel(nav: BrowserInfo = navigator): Promise<string | null> {
	const ua = nav.userAgent;
	if (/ipad/iu.test(ua)) {
		return "iPad";
	}
	if (/iphone|ipod/iu.test(ua)) {
		return "iPhone";
	}
	if (/android/iu.test(ua)) {
		const hinted = await nav.userAgentData?.getHighEntropyValues?.(["model"]).catch(() => null);
		const model = hinted?.model?.trim() || ANDROID_MODEL.exec(ua)?.groups?.model?.trim();
		return isModelName(model) ? model : "Android device";
	}
	if (/mac os|macintosh/iu.test(ua)) {
		// iPadOS Safari reports a Mac user agent; only touch support gives it away.
		return (nav.maxTouchPoints ?? 0) > 1 ? "iPad" : "Mac";
	}
	if (/windows/iu.test(ua)) {
		return "Windows PC";
	}
	if (/cros/iu.test(ua)) {
		return "Chromebook";
	}
	if (/linux/iu.test(ua)) {
		return "Linux PC";
	}
	return null;
}

export function parseUserAgentOs(ua: string | null | undefined): string | null {
	if (!ua) {
		return null;
	}
	if (/iphone|ipad|ipod/iu.test(ua)) {
		return "iOS";
	}
	if (/android/iu.test(ua)) {
		return "Android";
	}
	if (/mac os|macintosh/iu.test(ua)) {
		return "macOS";
	}
	if (/windows/iu.test(ua)) {
		return "Windows";
	}
	if (/linux/iu.test(ua)) {
		return "Linux";
	}
	return null;
}
