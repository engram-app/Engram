// Note text is LF only (the Relay model; backend `Engram.Notes.LineEndings`).
// Every `\r\n` and every lone `\r` becomes `\n`, the way CodeMirror splits lines.
// The one converter in the web app: point every CR rewrite here.
export function toLf(text: string): string {
	return text.replace(/\r\n?/g, "\n");
}
