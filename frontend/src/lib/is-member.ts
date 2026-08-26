/**
 * Narrows an unknown value to a member of a literal union by checking it
 * against that union's runtime list. Replaces the `list.includes(v as T)`
 * + `v as T` pair, which asserts the answer instead of proving it.
 *
 *   const VALID = ["light", "dark"] as const;
 *   if (isMember(VALID, raw)) { raw; // "light" | "dark", no cast }
 */
export function isMember<T extends string>(list: readonly T[], value: unknown): value is T {
	return typeof value === "string" && list.some((member) => member === value);
}
