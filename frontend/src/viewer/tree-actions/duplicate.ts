export function nextCopyName(path: string, existing: Set<string>): string {
	const slash = path.lastIndexOf("/");
	const folder = slash < 0 ? "" : path.slice(0, slash + 1);
	const name = slash < 0 ? path : path.slice(slash + 1);
	const dot = name.lastIndexOf(".");
	const stem = dot > 0 ? name.slice(0, dot) : name;
	const ext = dot > 0 ? name.slice(dot) : "";

	const candidate = (attempt: number) =>
		`${folder}${stem} (${attempt === 1 ? "copy" : `copy ${attempt}`})${ext}`;

	let n = 1;
	while (existing.has(candidate(n))) {
		n++;
	}
	return candidate(n);
}
