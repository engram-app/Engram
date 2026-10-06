import { describe, expect, it } from "vitest";
import { guessDeviceLabel } from "./guess-device-label";

const UA = {
	win: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130 Safari/537.36",
	mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17 Safari/605.1.15",
	linux: "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0",
	cros: "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
	iphone:
		"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
	ipad: "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
	pixel:
		"Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36",
	reducedAndroid:
		"Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36",
};

describe("guessDeviceLabel", () => {
	it.each([
		[UA.win, "Windows PC"],
		[UA.mac, "Mac"],
		[UA.linux, "Linux PC"],
		[UA.cros, "Chromebook"],
		[UA.iphone, "iPhone"],
		[UA.ipad, "iPad"],
		[UA.pixel, "Pixel 8"],
		[UA.reducedAndroid, "Android device"],
	])("names %#", async (userAgent, expected) => {
		expect(await guessDeviceLabel({ userAgent })).toBe(expected);
	});

	it("prefers the Client Hints model on a reduced Android user agent", async () => {
		const label = await guessDeviceLabel({
			userAgent: UA.reducedAndroid,
			userAgentData: { getHighEntropyValues: async () => ({ model: "Pixel 9 Pro" }) },
		});
		expect(label).toBe("Pixel 9 Pro");
	});

	it("falls back when Client Hints reject", async () => {
		const label = await guessDeviceLabel({
			userAgent: UA.pixel,
			userAgentData: {
				getHighEntropyValues: () => Promise.reject(new Error("blocked by permissions policy")),
			},
		});
		expect(label).toBe("Pixel 8");
	});

	it("tells an iPad in desktop mode from a Mac by touch support", async () => {
		expect(await guessDeviceLabel({ userAgent: UA.mac, maxTouchPoints: 5 })).toBe("iPad");
		expect(await guessDeviceLabel({ userAgent: UA.mac, maxTouchPoints: 0 })).toBe("Mac");
	});

	it("returns null when there is nothing to go on", async () => {
		expect(await guessDeviceLabel({ userAgent: "" })).toBeNull();
		expect(await guessDeviceLabel({ userAgent: "curl/8" })).toBeNull();
	});
});
