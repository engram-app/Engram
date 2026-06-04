// Seeded into the user's first vault on the "starting fresh" path so the
// dashboard isn't empty on arrival. The content shows off a few markdown
// features (callout, wikilink, code fence) so the editor renders something
// non-trivial. Update freely — it's not load-bearing.

export const WELCOME_NOTE_PATH = 'Welcome.md'

export const WELCOME_NOTE_CONTENT = `# Welcome to Engram

This is your first note. A few things you can try:

- **Edit me** — click the *Edit* tab above to switch from preview to markdown
- **Wikilinks** — type \`[[Another note]]\` to link between notes (we'll auto-create the target as a stub)
- **Tags** — drop \`#projects/example\` anywhere to organize and filter

> [!tip] Your AI tools see the same files
> Claude, Cursor, ChatGPT, and any MCP client read from this exact vault. Anything you write here is immediately searchable from inside those tools.

\`\`\`elixir
# Engram speaks plain markdown. Code fences render with syntax highlighting:
defmodule Hello do
  def world, do: "👋"
end
\`\`\`

Delete this note any time and start fresh — it's just a sample.
`
