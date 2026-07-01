interface CollideBumpOptions {
	/** Hard cap to avoid runaway loops on malformed input. Default 1000. */
	cap?: number;
}

/**
 * Find the first name in the sequence `base`, `base 1`, `base 2`, … that is
 * not in `existing`. For names with an extension (`Untitled.md`), the suffix
 * goes before the extension (`Untitled 1.md`). For names without an extension
 * (`Untitled folder`), the suffix goes at the end (`Untitled folder 1`).
 *
 * Throws if the cap is exceeded — caller should treat that as a logic bug
 * (the user almost certainly does not have 1000 Untitled.md files).
 */
export function collideBump(
	existing: ReadonlySet<string>,
	base: string,
	opts: CollideBumpOptions = {},
): string {
	const cap = opts.cap ?? 1000;
	const lastDot = base.lastIndexOf(".");
	const hasExtension = lastDot > 0;
	const stem = hasExtension ? base.slice(0, lastDot) : base;
	const extension = hasExtension ? base.slice(lastDot) : "";

	for (let i = 0; i < cap; i++) {
		const candidate = i === 0 ? base : `${stem} ${i}${extension}`;
		if (!existing.has(candidate)) {
			return candidate;
		}
	}
	throw new Error(`collideBump: too many collisions for "${base}" (cap ${cap})`);
}
