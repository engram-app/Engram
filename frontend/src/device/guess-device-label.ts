function osOf(ua: string | null | undefined): string | null {
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

// Android WebView and Chrome reduce the model to a bare "K" (UA reduction),
// so a one-letter token is not a model name.
const ANDROID_MODEL = /Android[^;)]*;\s*(?<model>[^;)]+?)(?:\s+Build\/[^;)]*)?[;)]/iu;

// A suggested connection name from the plugin's User-Agent. iOS never reports
// the model, so an iPhone is just "iPhone"; only Android sometimes does.
export function guessDeviceLabel(ua: string | null | undefined): string | null {
	if (!ua) {
		return null;
	}
	if (/ipad/iu.test(ua)) {
		return "iPad";
	}
	if (/iphone|ipod/iu.test(ua)) {
		return "iPhone";
	}
	if (/android/iu.test(ua)) {
		const model = ANDROID_MODEL.exec(ua)?.groups?.model?.trim();
		return model && model.length > 1 && !/^(?:wv|mobile)$/iu.test(model) ? model : "Android device";
	}
	switch (osOf(ua)) {
		case "macOS":
			return "Mac";
		case "Windows":
			return "Windows PC";
		case "Linux":
			return "Linux PC";
		default:
			return null;
	}
}

export { osOf as parseUserAgentOs };
