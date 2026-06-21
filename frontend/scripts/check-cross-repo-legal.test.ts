import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
	diffManifests,
	manifestFromMarkdown,
	type Manifest,
} from "./check-cross-repo-legal";

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

describe("manifestFromMarkdown", () => {
	it("maps terms-/privacy- filenames to doc+version+sha256", () => {
		const files = {
			"terms-2026-05-19.md": Buffer.from("the terms"),
			"privacy-2026-06-20.md": Buffer.from("the privacy"),
			"README.md": Buffer.from("ignored, no prefix"),
		};
		expect(manifestFromMarkdown(files)).toEqual({
			terms_of_service: { "2026-05-19": sha("the terms") },
			privacy_policy: { "2026-06-20": sha("the privacy") },
		});
	});
});

describe("diffManifests", () => {
	const base: Manifest = {
		terms_of_service: { "2026-05-19": "aaa" },
		privacy_policy: { "2026-06-20": "bbb" },
	};

	it("returns no errors when all sources agree", () => {
		expect(
			diffManifests({
				backend: base,
				frontend: structuredClone(base),
				marketing: structuredClone(base),
			}),
		).toEqual([]);
	});

	it("flags a hash mismatch on one source", () => {
		const drifted = structuredClone(base);
		drifted.privacy_policy["2026-06-20"] = "ZZZ";
		const errors = diffManifests({ backend: base, marketing: drifted });
		expect(errors).toHaveLength(1);
		expect(errors[0]).toContain("privacy_policy 2026-06-20");
		expect(errors[0]).toContain("backend=bbb");
		expect(errors[0]).toContain("marketing=ZZZ");
	});

	it("flags a version present in one source but missing from another", () => {
		const extra = structuredClone(base);
		extra.terms_of_service["2027-01-01"] = "ccc";
		const errors = diffManifests({ backend: base, frontend: extra });
		expect(errors).toHaveLength(1);
		expect(errors[0]).toContain("terms_of_service 2027-01-01");
		expect(errors[0]).toContain("backend=MISSING");
		expect(errors[0]).toContain("frontend=ccc");
	});

	it("is a no-op with fewer than two sources", () => {
		expect(diffManifests({ backend: base })).toEqual([]);
	});
});
