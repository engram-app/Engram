defmodule Engram.Vaults.WelcomeNote do
  @moduledoc """
  The sample note seeded into every newly created vault, so a first-run vault
  explains the web app instead of being empty.

  Seeded from the two controllers that create vaults — `VaultsController.register`
  and `DeviceAuthController.authorize` — rather than from `Vaults.register_vault`
  itself. Those two are the only production callers, so this covers every real
  vault creation, while `register_vault`'s ~270 test callers keep registering
  empty vaults. Seeding in the context would also make `change_seq` and
  `usage_meters.notes_count` start at 1 for a "fresh" vault, which several tests
  correctly assert is 0.

  The prose is not load-bearing — edit it freely. What IS pinned by
  `Engram.Vaults.WelcomeNoteTest`: the frontmatter block (the properties widget
  parses it), the absence of an H1 (the SPA's inline title already renders the
  filename as one), and the absence of markdown the web viewer does not render.
  Before adding a syntax here, check `frontend/src/viewer/reference/markdown-syntax.ts`
  — foldable callouts (`> [!tip]-`), `==highlight==`, raw HTML and `%%comments%%`
  are all deliberately unsupported. Footnotes render in Reading view but NOT in
  the editor (no node for them in @lezer/markdown's GFM bundle), so this note
  deliberately uses none — see docs/context/codemirror-footnote-options.md.
  """

  alias Engram.Logger.Metadata
  alias Engram.Notes

  require Logger

  @path "Welcome to Engram.md"

  # `~S` (no interpolation, no escapes) so the KaTeX backslashes and mermaid
  # braces survive verbatim. The date is substituted below rather than
  # interpolated for the same reason.
  @template ~S"""
  ---
  tags: [example]
  created: {{created}}
  done: false
  ---

  ## Try these

  - [ ] Click this line. You're editing — no save button, it syncs as you type.
  - [ ] Type `[[` anywhere to link another note. That note gets a **Backlinks** entry pointing back here.
  - [ ] Add `#example` to any line. Tags filter across folders; a note can carry as many as you like.
  - [ ] Open **search** in the sidebar, then try a phrase you never typed — it matches meaning, not keywords.
  - [ ] Tick one of these boxes. Task lists are just `- [ ]`.

  ## Where your notes live

  ```mermaid
  flowchart LR
    O[Obsidian] <--> E[(Engram)]
    W[This web app] <--> E
    E <--> A[Claude, Cursor, ChatGPT]
  ```

  One vault, three doors. Edit in any of them and it shows up in the others — no export step, no second copy. Same files, same bytes.

  ## Properties

  The fields above this note's text are its [frontmatter](https://obsidian.md/help/properties): plain [YAML](https://learnxinyminutes.com/yaml/) in the file, editable fields here. To add them to a note that has none, type `---` on the very first line, or open the kebab menu (`⋮`) and pick **Add property**.

  | Type | Example |
  | --- | --- |
  | `text` | `status: draft` |
  | `list` | `tags: [example]` |
  | `number` | `priority: 2` |
  | `checkbox` | `done: false` |
  | `date` | `created: 2026-09-02` |
  | `datetime` | `due: 2026-09-02T17:00` |

  ## Reading, editing, and the source

  The ✏️ button in the header flips between editing and reading, and it shows the mode you are **in** — a pencil means you're editing, a book means you're reading. Flip back and you land in whichever editor you left, not a default.

  The kebab names all three, with the same icons, so you can jump straight to one:

  | Icon | Mode | What you get |
  | --- | --- | --- |
  | ✏️ | **Edit** | Live preview: `**bold**` becomes **bold** as you type. This is the default. |
  | `</>` | **Raw** | The plain source: `**bold**` stays `**bold**`, and the properties above turn back into YAML text. |
  | 📖 | **Reading** | Read-only. No cursor to nudge anything out of place. |

  > [!tip] Finish setup
  > The panel in the bottom right walks you through connecting Obsidian and your AI tools. It disappears once you're done. Full guides: [engram.page/docs](https://engram.page/docs)

  The rest of what you'd expect works too — ~~strikethrough~~, `inline code`, KaTeX like $e^{i\pi} + 1 = 0$, and fences with syntax highlighting:

  ```python
  def remember(thought: str) -> None:
      # Anything you write here, your AI tools can read.
      vault.write(thought)
  ```

  Delete this note whenever — it's only markdown.
  """

  @doc "Path of the seeded note, relative to the vault root."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  The note body, with `date` stamped into the `created` property so a brand-new
  vault's first note doesn't open showing a hardcoded date from whenever this
  file was last edited.
  """
  @spec content(Date.t()) :: String.t()
  def content(date \\ Date.utc_today()) do
    String.replace(@template, "{{created}}", Date.to_iso8601(date))
  end

  @doc """
  Writes the welcome note into `vault`.

  Best-effort by design: a failure is logged and swallowed. The vault has
  already committed by the time this runs, so raising here would 500 a request
  whose real work succeeded — and a vault missing its sample note is recoverable
  in a way a caller that believes vault creation failed is not.
  """
  @spec seed(Engram.Accounts.User.t(), Engram.Vaults.Vault.t()) :: :ok
  def seed(user, vault) do
    do_seed(user, vault)
  rescue
    # `upsert_note` does not only return tagged errors — it RAISES on a decrypt
    # failure, a Repo/Postgrex error and a couple of `{:ok, _} =` matches. The
    # vault row has already committed by the time we get here, so letting any of
    # those escape 500s a request whose real work succeeded. That is the exact
    # failure this function exists to avoid, so the rescue has to be as wide as
    # the swallow the docstring promises.
    error ->
      Logger.warning(
        "welcome note seed raised",
        Metadata.with_category(:warning, :lifecycle,
          user_id: user.id,
          vault_id: vault.id,
          reason: Metadata.safe_reason(error)
        )
      )

      :ok
  end

  defp do_seed(user, vault) do
    attrs = %{
      "path" => @path,
      "content" => content(),
      "mtime" => :os.system_time(:second) / 1
    }

    # `announce_vault_populated: false` is load-bearing: this write is note #1,
    # so without it the seed itself satisfies the 0->1 probe behind the
    # `vault_populated` event and forwards the onboarding and /link waiting
    # screens before the user's real first sync has pushed anything.
    case Notes.upsert_note(user, vault, attrs, announce_vault_populated: false) do
      {:ok, _note} ->
        :ok

      other ->
        Logger.warning(
          "welcome note seed failed",
          Metadata.with_category(:warning, :lifecycle,
            user_id: user.id,
            vault_id: vault.id,
            reason: seed_reason(other)
          )
        )

        :ok
    end
  end

  # `safe_reason/1` on the whole tuple renders a bare ":error" — every failure
  # shape `upsert_note/4` returns is `{:error, _}` or `{:error, _, _}`, so
  # unwrap one level to reach the tag that names what actually went wrong.
  defp seed_reason({:error, reason}), do: Metadata.safe_reason(reason)
  defp seed_reason({:error, reason, _}), do: Metadata.safe_reason(reason)
end
