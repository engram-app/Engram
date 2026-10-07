// The existing vault to suggest for the name the plugin sent. Linking notes
// into the wrong vault is worse than not suggesting one, so an ambiguous
// case-insensitive match (several vaults, none exact) suggests nothing.
export function findMatchingVault<T extends { name: string }>(
	vaults: T[],
	name: string,
): T | undefined {
	const wanted = name.trim();
	if (!wanted) {
		return undefined;
	}
	const needle = wanted.toLowerCase();
	const fits = vaults.filter((v) => v.name.trim().toLowerCase() === needle);
	return fits.find((v) => v.name.trim() === wanted) ?? (fits.length === 1 ? fits[0] : undefined);
}
