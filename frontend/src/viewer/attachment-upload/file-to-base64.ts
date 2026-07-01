// Read a File's bytes as bare base64 (no `data:<mime>;base64,` prefix), which
// is the shape `POST /api/attachments` expects for `content_base64`.
export function fileToBase64(file: File): Promise<string> {
	return new Promise((resolve, reject) => {
		const reader = new FileReader();
		reader.onerror = () => reject(reader.error ?? new Error("file read failed"));
		reader.onload = () => {
			const { result } = reader;
			if (typeof result !== "string") {
				reject(new Error("unexpected FileReader result"));
				return;
			}
			// result is `data:<mime>;base64,<payload>` — keep only the payload.
			const comma = result.indexOf(",");
			resolve(comma === -1 ? "" : result.slice(comma + 1));
		};
		reader.readAsDataURL(file);
	});
}
