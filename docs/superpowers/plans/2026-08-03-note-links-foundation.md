# Note Links Foundation Implementation Plan (backend, closes #591)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every wikilink/embed as a `note_links` edge row, extracted server-side at index time, with Obsidian-style resolution, dangling-link binding, rotation integration, backfill, and links/backlinks APIs.

**Architecture:** A pure `LinkParser` extracts `[[...]]`/`![[...]]` from decrypted content inside the existing indexing pass (`Engram.Indexing`). A `Engram.Links` context encrypts/persists edges and resolves targets via a new `basename_hmac` column on notes/attachments (lowercased, `.md`/`.canvas`-stripped basename → indexed HMAC lookup, decrypt only candidates). Lifecycle hooks on rename/delete/create keep edges correct; an Oban backfill populates existing vaults.

**Tech Stack:** Elixir/Phoenix, Ecto (Postgres + RLS), Oban, AES-256-GCM envelope crypto (`Engram.Crypto.Envelope`), OpenApiSpex.

**Spec:** Engram vault → `50 Engineering/_Superpowers Specs/2026-08-03-note-links-graph-design.md`. Read it first.

## Global Constraints

- Migrations are **expand-only**: filename suffix `_expand.exs`, in-file `# phase/expand — ...` comment, PR label `phase/expand` (CI job `phase-label-required` enforces exactly one).
- New table needs `# squawk-ignore-file` justification for non-CONCURRENTLY indexes (fresh empty table).
- Register `note_links` in `Engram.Repo.@tenant_tables` (`lib/engram/repo.ex:16`) — RLS lint tests source from it; `test/engram/rls_coverage_test.exs` hard-fails on unlisted `user_id` tables.
- All new regexes over user content MUST be `u`-flagged; extracted strings go through `Engram.Notes.Helpers.scrub_utf8(:write, ...)` before hashing/encrypting (prod bug #741).
- AAD binding: `Crypto.aad_for_row(:note_links, <column>, row_id)` — row UUID must be minted **before** encrypting (`Engram.Notes.mint_id/0`).
- Timestamps `:timestamptz`; PK `uuid DEFAULT uuidv7()`; no version bumps (release-please owns mix.exs).
- Gauntlet before push, run SEQUENTIALLY: `mix format` → `mix credo --strict` → `mix dialyzer` → full `mix test --warnings-as-errors`.
- Commit after each task. Branch: `feat/note-links-foundation` (this worktree).

---

### Task 1: Migration — `note_links` table + `basename_hmac` columns

**Files:**
- Create: `priv/repo/migrations/<UTC yyyymmddHHMMSS>_create_note_links_expand.exs`
- Create: `priv/repo/migrations/<UTC +1s>_add_basename_hmac_expand.exs`
- Modify: `lib/engram/repo.ex:16` (`@tenant_tables`)

**Interfaces:**
- Produces: table `note_links` (columns below), `notes.basename_hmac :binary null`, `attachments.basename_hmac :binary null`.

- [ ] **Step 1: Write the note_links migration** (model: `20260625140000_create_crdt_update_log_expand.exs`)

```elixir
defmodule Engram.Repo.Migrations.CreateNoteLinksExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — new empty table; indexes created non-CONCURRENTLY are safe
  # because there are zero rows at creation time.
  #
  # WHY. One row per wikilink/embed occurrence in a note (issue #591). Edges are
  # keyed by note UUIDs so renames never invalidate them. target_note_id NULL =
  # dangling link; target_basename_hmac is the only resolution lookup key
  # (case-insensitive Obsidian rules make full-path HMACs unusable). Raw typed
  # target/alias/anchor are encrypted, AAD-bound per row (T3.6 pattern).
  def change do
    create table(:note_links, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :source_note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :target_note_id, references(:notes, type: :uuid, on_delete: :nilify_all)
      add :target_attachment_id,
          references(:attachments, type: :uuid, on_delete: :nilify_all)
      add :target_text_ciphertext, :binary, null: false
      add :target_text_nonce, :binary, null: false
      add :target_basename_hmac, :binary, null: false
      add :link_type, :text, null: false
      add :alias_ciphertext, :binary
      add :alias_nonce, :binary
      add :anchor_ciphertext, :binary
      add :anchor_nonce, :binary
      add :position, :integer, null: false
      add :dek_version, :integer, null: false, default: 2
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create constraint(:note_links, :note_links_link_type_check,
             check: "link_type IN ('wikilink', 'embed')"
           )

    create unique_index(:note_links, [:source_note_id, :position])
    create index(:note_links, [:user_id, :vault_id, :source_note_id])
    create index(:note_links, [:user_id, :vault_id, :target_note_id])
    create index(:note_links, [:user_id, :vault_id, :target_attachment_id])

    create index(:note_links, [:user_id, :vault_id, :target_basename_hmac],
             where: "target_note_id IS NULL AND target_attachment_id IS NULL",
             name: :note_links_dangling_basename_idx
           )

    execute(
      "ALTER TABLE note_links ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE note_links DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE note_links FORCE ROW LEVEL SECURITY",
      "ALTER TABLE note_links NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_note_links ON note_links
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_note_links ON note_links"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON note_links TO engram_app",
      "REVOKE ALL ON note_links FROM engram_app"
    )
  end
end
```

Note `on_delete: :nilify_all` for the two target FKs — DB-level enforcement of "delete flips incoming edges to dangling"; app code additionally handles soft-delete (Task 6) since soft-delete never fires FK actions.

- [ ] **Step 2: Write the basename_hmac migration**

```elixir
defmodule Engram.Repo.Migrations.AddBasenameHmacExpand do
  use Ecto.Migration

  # phase/expand — nullable columns, no backfill here (Oban backfill, Task 8).
  # WHY. HMAC of lowercased, .md/.canvas-stripped basename. Makes Obsidian-style
  # case-insensitive link resolution an indexed lookup with zero bulk decryption.
  def change do
    alter table(:notes) do
      add :basename_hmac, :binary
    end

    alter table(:attachments) do
      add :basename_hmac, :binary
    end
  end
end
```

⚠️ Adding an index on `notes.basename_hmac`/`attachments.basename_hmac` (non-empty tables) MUST be `create index(..., concurrently: true)` in a separate `@disable_ddl_transaction true` migration — add a third migration file `<UTC +2s>_index_basename_hmac_expand.exs`:

```elixir
defmodule Engram.Repo.Migrations.IndexBasenameHmacExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # phase/expand — CONCURRENTLY: notes/attachments are populated tables.
  def change do
    create index(:notes, [:user_id, :vault_id, :basename_hmac],
             concurrently: true,
             where: "deleted_at IS NULL"
           )

    create index(:attachments, [:user_id, :vault_id, :basename_hmac],
             concurrently: true,
             where: "deleted_at IS NULL"
           )
  end
end
```

- [ ] **Step 3: Register tenant table** — in `lib/engram/repo.ex` change `@tenant_tables` to append `note_links`:

```elixir
@tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements onboarding_actions crdt_update_log note_links)a
```

- [ ] **Step 4: Run migrations + linters**

Run: `mix ecto.migrate` then `mix test test/lint/migration_rls_lint_test.exs test/engram/rls_coverage_test.exs test/engram/rls_policy_form_test.exs`
Expected: PASS (rls_coverage picks up note_links via tenant_tables; if it fails, read its output — do NOT allowlist).

- [ ] **Step 5: Commit** — `git add priv/repo/migrations lib/engram/repo.ex && git commit -m "feat(links): note_links table + basename_hmac columns (expand)"`

---

### Task 2: `Engram.Links.Parser` — pure extraction

**Files:**
- Create: `lib/engram/links/parser.ex`
- Test: `test/engram/links/parser_test.exs`

**Interfaces:**
- Produces: `Parser.extract(content :: String.t()) :: [%{target: String.t(), alias: String.t() | nil, anchor: String.t() | nil, link_type: String.t(), position: non_neg_integer()}]` — `link_type` ∈ `"wikilink" | "embed"`; `position` = byte offset of the `[[`/`![[` in the ORIGINAL content; targets/aliases/anchors trimmed, UTF-8 scrubbed. Links inside fenced/inline code and frontmatter are excluded. Empty targets (`[[]]`, `[[#h]]` with no page) are skipped (`[[#h]]` is same-page navigation; no edge).
- Consumes: `Engram.Notes.Helpers.scrub_utf8/2` (existing, public).

- [ ] **Step 1: Write failing tests**

```elixir
defmodule Engram.Links.ParserTest do
  use ExUnit.Case, async: true

  alias Engram.Links.Parser

  test "extracts a plain wikilink with its position" do
    assert [%{target: "Foo", alias: nil, anchor: nil, link_type: "wikilink", position: 4}] =
             Parser.extract("See [[Foo]].")
  end

  test "extracts alias, heading anchor, and block anchor" do
    content = "[[Page|shown]] and [[Page#Heading]] and [[Page#^blockid]]"

    assert [
             %{target: "Page", alias: "shown", anchor: nil},
             %{target: "Page", anchor: "Heading"},
             %{target: "Page", anchor: "^blockid"}
           ] = Parser.extract(content)
  end

  test "embeds get link_type embed" do
    assert [%{target: "image.png", link_type: "embed"}] = Parser.extract("![[image.png]]")
  end

  test "ignores links inside fenced code, inline code, and frontmatter" do
    content = """
    ---
    title: has [[NotALink]]
    ---
    `[[inline nope]]`

    ```
    [[fenced nope]]
    ```

    [[Real]]
    """

    assert [%{target: "Real"}] = Parser.extract(content)
  end

  test "skips empty and same-page-anchor-only targets" do
    assert [] = Parser.extract("[[]] and [[#Just A Heading]]")
  end

  test "multibyte content does not shift positions into invalid offsets" do
    # u-flag regression guard (prod bug #741 class)
    content = "émoji 🎉 then [[Café]]"
    assert [%{target: "Café", position: pos}] = Parser.extract(content)
    assert binary_part(content, pos, 2) == "[["
  end

  test "empty content extracts nothing" do
    assert [] = Parser.extract("")
  end
end
```

- [ ] **Step 2: Run to verify failure** — `mix test test/engram/links/parser_test.exs` → FAIL (module undefined).

- [ ] **Step 3: Implement**

Implementation notes: to keep positions accurate while excluding code/frontmatter, do NOT strip-then-scan (offsets would shift). Instead scan the original with a `u`-flagged regex and collect excluded ranges first, then filter matches whose start falls inside any excluded range.

```elixir
defmodule Engram.Links.Parser do
  @moduledoc """
  Pure extraction of Obsidian-style wikilinks/embeds from plaintext markdown.
  Positions are byte offsets into the ORIGINAL content (stable for snippet
  reconstruction), which is why exclusion works by range-filtering rather than
  stripping (stripping would shift every downstream offset).
  """

  alias Engram.Notes.Helpers

  # `!` optional (embed), lazy target up to `]]`; `u` flag is load-bearing (#741).
  @link_re ~r/(!?)\[\[([^\]\[]+?)\]\]/u

  # Ranges to exclude: fenced code, inline code. Frontmatter handled separately.
  @exclusion_res [~r/```.*?```/su, ~r/~~~.*?~~~/su, ~r/`[^`\n]*`/u]
  @frontmatter_re ~r/\A---\s*\n.*?\n---\s*\n/su

  @spec extract(String.t()) :: [map()]
  def extract(content) when is_binary(content) do
    excluded = exclusion_ranges(content)

    @link_re
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _len}, {_, bang_len}, {inner_start, inner_len}] ->
      inner = binary_part(content, inner_start, inner_len)

      case parse_inner(inner) do
        nil -> []
        parsed -> [Map.merge(parsed, %{link_type: link_type(bang_len), position: start})]
      end
    end)
    |> Enum.reject(fn %{position: pos} -> in_ranges?(pos, excluded) end)
  end

  defp link_type(0), do: "wikilink"
  defp link_type(_), do: "embed"

  defp parse_inner(inner) do
    {body, alias_} =
      case String.split(inner, "|", parts: 2) do
        [body] -> {body, nil}
        [body, a] -> {body, clean(a)}
      end

    {target, anchor} =
      case String.split(body, "#", parts: 2) do
        [t] -> {clean(t), nil}
        [t, an] -> {clean(t), clean(an)}
      end

    if target in [nil, ""] do
      nil
    else
      %{target: target, alias: alias_, anchor: anchor}
    end
  end

  defp clean(nil), do: nil

  defp clean(s) do
    case s |> String.trim() |> Helpers.scrub_utf8(:write) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp exclusion_ranges(content) do
    fm =
      case Regex.run(@frontmatter_re, content, return: :index) do
        [{0, len} | _] -> [{0, len}]
        _ -> []
      end

    code =
      Enum.flat_map(@exclusion_res, fn re ->
        re |> Regex.scan(content, return: :index) |> Enum.map(fn [{s, l} | _] -> {s, l} end)
      end)

    fm ++ code
  end

  defp in_ranges?(pos, ranges),
    do: Enum.any?(ranges, fn {s, l} -> pos >= s and pos < s + l end)
end
```

⚠️ Check `Helpers.scrub_utf8/2`'s actual arity/signature first (`lib/engram/notes/helpers.ex`) — if it is `scrub_utf8(value, :write)` or has a different name/order, adapt `clean/1` to the real API; do not redefine scrubbing locally.

- [ ] **Step 4: Run tests** — `mix test test/engram/links/parser_test.exs` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): wikilink/embed parser with code-fence exclusion"`

---

### Task 3: `Engram.Links` context — schema, encryption, resolution

**Files:**
- Create: `lib/engram/links/note_link.ex` (Ecto schema)
- Create: `lib/engram/links.ex` (context)
- Test: `test/engram/links_test.exs`

**Interfaces:**
- Consumes: `Parser.extract/1` (Task 2); `Engram.Crypto.{get_dek/1, dek_filter_key/1, hmac_field/2, aad_for_row/3}`; `Engram.Crypto.Envelope.{encrypt/3, decrypt/4}`; `Engram.Notes.mint_id/0`.
- Produces:
  - `Links.basename_key(String.t()) :: String.t()` — lowercased basename, `.md`/`.canvas` stripped (other extensions kept).
  - `Links.replace_links(user, vault, note_id, parsed :: [map()]) :: :ok` — delete+insert edges for a source note, resolving each target. Runs inside caller's tenant/skip_tenant context (`skip_tenant_check: true`, mirrors `Indexing.commit_index/1`).
  - `Links.resolve_target(user, vault, target :: String.t(), link_type :: String.t()) :: {:note, id} | {:attachment, id} | :dangling`
  - `Links.links_for_note(user, note_id) :: [%{target_text, target_note_id, target_attachment_id, target_path, alias, anchor, link_type, dangling}]` (decrypted; `target_path` only when resolved to a note).
  - `Links.backlinks_for_note(user, note_id) :: [%{source_note_id, source_path, source_title, alias, anchor}]`
  - `Links.bind_danglers_for(user, vault, basename_key :: String.t()) :: :ok` — re-resolve all dangling AND currently-bound edges whose `target_basename_hmac` matches (winner may change; see spec lifecycle matrix).
  - `Links.on_note_soft_deleted(user_id, note_id) :: :ok` — delete outgoing, flip incoming to dangling.

- [ ] **Step 1: Schema** (no test needed — exercised via context tests)

```elixir
defmodule Engram.Links.NoteLink do
  use Engram.Schema

  schema "note_links" do
    field :target_text, :string, virtual: true
    field :alias, :string, virtual: true
    field :anchor, :string, virtual: true

    field :target_text_ciphertext, :binary
    field :target_text_nonce, :binary
    field :target_basename_hmac, :binary
    field :alias_ciphertext, :binary
    field :alias_nonce, :binary
    field :anchor_ciphertext, :binary
    field :anchor_nonce, :binary
    field :link_type, :string
    field :position, :integer
    field :dek_version, :integer, default: 2

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault
    belongs_to :source_note, Engram.Notes.Note
    belongs_to :target_note, Engram.Notes.Note
    belongs_to :target_attachment, Engram.Attachments.Attachment

    timestamps(type: :utc_datetime_usec, inserted_at: :inserted_at, updated_at: false)
  end
end
```

⚠️ Check `Engram.Schema` (`lib/engram/schema.ex`) for the house `use` macro defaults (PK type etc.) and mirror `note.ex`. If `timestamps(updated_at: false)` fights the macro, fall back to a plain `field :inserted_at, :utc_datetime_usec`.

- [ ] **Step 2: Write failing context tests** (representative set — write ALL of these)

```elixir
defmodule Engram.LinksTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.NoteLink

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "basename_key/1" do
    test "lowercases and strips note extensions only" do
      assert Links.basename_key("Folder/My Note.md") == "my note"
      assert Links.basename_key("My Note") == "my note"
      assert Links.basename_key("Board.canvas") == "board"
      assert Links.basename_key("pics/Photo.PNG") == "photo.png"
    end
  end

  describe "replace_links/4 + resolve" do
    test "resolves exact path, case-insensitively", %{user: user, vault: vault} do
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Sub/Target.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      parsed = [%{target: "sub/target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}]
      :ok = Links.replace_links(user, vault, source.id, parsed)

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_note_id == target.id
    end

    test "basename resolution picks the shortest path, lexicographic tiebreak", %{user: user, vault: vault} do
      _long = Engram.Fixtures.insert_note!(user, vault, %{path: "a/b/c/Dup.md"})
      short = Engram.Fixtures.insert_note!(user, vault, %{path: "a/Dup.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Dup", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_note_id == short.id
    end

    test "unresolvable target stores a dangling edge with hmac + ciphertext", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Ghost", alias: "shown", anchor: "H", link_type: "wikilink", position: 7}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert is_nil(link.target_note_id)
      assert is_nil(link.target_attachment_id)
      assert byte_size(link.target_basename_hmac) == 32
      # decrypts back
      [decrypted] = Links.links_for_note(user, source.id)
      assert %{target_text: "Ghost", alias: "shown", anchor: "H", dangling: true} = decrypted
    end

    test "embed with binary extension resolves to an attachment", %{user: user, vault: vault} do
      # insert an attachment with real path crypto — mirror Fixtures.insert_note!
      # (add Engram.Fixtures.insert_attachment!/3 if it does not exist; same
      # Envelope.encrypt + hmac_field pattern over the attachments schema)
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "pics/image.png"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "image.png", alias: nil, anchor: nil, link_type: "embed", position: 0}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_attachment_id == att.id
    end

    test "replace is idempotent — re-running replaces, never duplicates", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      parsed = [%{target: "X", alias: nil, anchor: nil, link_type: "wikilink", position: 0}]
      :ok = Links.replace_links(user, vault, source.id, parsed)
      :ok = Links.replace_links(user, vault, source.id, parsed)
      {:ok, links} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert length(links) == 1
    end

    test "empty parsed list clears all edges for the source", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      :ok = Links.replace_links(user, vault, source.id, [
        %{target: "X", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])
      :ok = Links.replace_links(user, vault, source.id, [])
      {:ok, []} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
    end
  end

  describe "bind_danglers_for/3" do
    test "binds a dangler when its target is created", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      :ok = Links.replace_links(user, vault, source.id, [
        %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

      target = Engram.Fixtures.insert_note!(user, vault, %{path: "deep/Later.md"})
      :ok = Links.bind_danglers_for(user, vault, Links.basename_key("deep/Later.md"))

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_note_id == target.id
    end

    test "a shorter-path newcomer steals the binding", %{user: user, vault: vault} do
      old = Engram.Fixtures.insert_note!(user, vault, %{path: "a/b/Win.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      :ok = Links.replace_links(user, vault, source.id, [
        %{target: "Win", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])
      {:ok, [l0]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert l0.target_note_id == old.id

      new = Engram.Fixtures.insert_note!(user, vault, %{path: "Win.md"})
      :ok = Links.bind_danglers_for(user, vault, "win")

      {:ok, [l1]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert l1.target_note_id == new.id
    end
  end

  describe "on_note_soft_deleted/2" do
    test "drops outgoing and flips incoming to dangling", %{user: user, vault: vault} do
      a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md"})
      b = Engram.Fixtures.insert_note!(user, vault, %{path: "B.md"})
      :ok = Links.replace_links(user, vault, a.id, [
        %{target: "B", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])
      :ok = Links.replace_links(user, vault, b.id, [
        %{target: "A", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

      :ok = Links.on_note_soft_deleted(user.id, b.id)

      {:ok, links} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      # b's outgoing edge is gone; a's edge to b is dangling again
      assert [%{source_note_id: source_id, target_note_id: nil}] = links
      assert source_id == a.id
    end
  end

  describe "backlinks_for_note/2" do
    test "returns sources with decrypted path/title", %{user: user, vault: vault} do
      a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md", title: "Note A"})
      b = Engram.Fixtures.insert_note!(user, vault, %{path: "B.md"})
      :ok = Links.replace_links(user, vault, a.id, [
        %{target: "B", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

      assert [%{source_note_id: sid, source_path: "A.md"}] = Links.backlinks_for_note(user, b.id)
      assert sid == a.id
    end
  end

  test "RLS: user B cannot see user A's links", %{user: user, vault: vault} do
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "S.md"})
    :ok = Links.replace_links(user, vault, source.id, [
      %{target: "X", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
    ])

    other = insert(:user)
    {:ok, links} = Repo.with_tenant(other.id, fn -> Repo.all(NoteLink) end)
    assert links == []
  end
end
```

- [ ] **Step 3: Run to verify failures** — `mix test test/engram/links_test.exs` → FAIL (module undefined). If `Engram.Fixtures.insert_attachment!/3` doesn't exist, add it in this task (mirror `insert_note!/3`, columns from `attachment.ex`, include `basename_hmac`).

- [ ] **Step 4: Implement `Engram.Links`**

Core shapes (adapt details against the real code, keep signatures):

```elixir
defmodule Engram.Links do
  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Links.NoteLink
  alias Engram.Repo

  @note_exts ~w(.md .canvas)

  @spec basename_key(String.t()) :: String.t()
  def basename_key(path_or_target) do
    base = path_or_target |> String.split("/") |> List.last() |> String.downcase()
    ext = Path.extname(base)
    if ext in @note_exts, do: String.replace_suffix(base, ext, ""), else: base
  end

  def replace_links(user, vault, source_note_id, parsed) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    now = DateTime.utc_now()

    rows =
      Enum.map(parsed, fn p ->
        id = Engram.Notes.mint_id()

        {tct, tnonce} =
          Envelope.encrypt(p.target, dek, Crypto.aad_for_row(:note_links, :target_text, id))

        {target_note_id, target_attachment_id} =
          case resolve_target(user, vault, p.target, p.link_type) do
            {:note, nid} -> {nid, nil}
            {:attachment, aid} -> {nil, aid}
            :dangling -> {nil, nil}
          end

        %{
          id: id,
          user_id: user.id,
          vault_id: vault.id,
          source_note_id: source_note_id,
          target_note_id: target_note_id,
          target_attachment_id: target_attachment_id,
          target_text_ciphertext: tct,
          target_text_nonce: tnonce,
          target_basename_hmac: Crypto.hmac_field(filter_key, basename_key(p.target)),
          link_type: p.link_type,
          position: p.position,
          dek_version: Crypto.row_version_aad_bound(),
          inserted_at: now
        }
        |> put_optional_envelope(:alias, p.alias, dek, id)
        |> put_optional_envelope(:anchor, p.anchor, dek, id)
      end)

    Repo.delete_all(
      from(l in NoteLink, where: l.source_note_id == ^source_note_id),
      skip_tenant_check: true
    )

    if rows != [], do: Repo.insert_all(NoteLink, rows, skip_tenant_check: true)
    :ok
  end
  # put_optional_envelope/5: nil value -> puts nil ct+nonce keys; else
  # Envelope.encrypt(value, dek, Crypto.aad_for_row(:note_links, field, id)).
end
```

Resolution (`resolve_target/4`): compute `key = basename_key(target)`; candidates = live notes with `basename_hmac == Crypto.hmac_field(filter_key, key)` (plus attachments when `link_type == "embed"` OR the target has a non-note extension); decrypt candidate paths (reuse the decrypt pattern from `Crypto.maybe_decrypt_note_fields/2` or select ciphertext+nonce and `Envelope.decrypt` with `aad_for_row(:notes, :path, id)` respecting `dek_version`); if `target` contains `/`, keep only candidates whose full path matches case-insensitively (input with/without `.md`/`.canvas` suffix); pick shortest `String.length(path)`, tie → lexicographically smallest path. Note-extension targets and extensionless targets resolve against notes; other extensions against attachments.

`bind_danglers_for/3`: select ALL edges (dangling or bound) in the vault with `target_basename_hmac == hmac_field(filter_key, key)`, decrypt each `target_text`, re-run `resolve_target/4`, `Repo.update_all` per changed edge (`skip_tenant_check: true`).

`on_note_soft_deleted/2`: two statements, both `skip_tenant_check: true`:

```elixir
Repo.delete_all(from(l in NoteLink, where: l.source_note_id == ^note_id), skip_tenant_check: true)
Repo.update_all(
  from(l in NoteLink, where: l.target_note_id == ^note_id),
  [set: [target_note_id: nil]],
  skip_tenant_check: true
)
```

`links_for_note/2` + `backlinks_for_note/2`: query by source/target id, decrypt link fields with `aad_for_row(:note_links, field, link.id)`; backlinks join source notes and decrypt their `path`/`title` (AAD `:notes`/field/note id per `dek_version`).

- [ ] **Step 5: Run tests** — `mix test test/engram/links_test.exs` → PASS.
- [ ] **Step 6: Commit** — `git commit -m "feat(links): Links context — encrypt, resolve, bind, backlinks"`

---

### Task 4: basename_hmac on note/attachment write paths

**Files:**
- Modify: `lib/engram/notes.ex` — `phase_b_path_folder_for/4` (`:4648`), `phase_b_keyword_for/5` (`:4483`), batch insert row builder (`:2649` / `:2337` area)
- Modify: attachment upsert path (find via `grep -n path_hmac lib/engram/attachments.ex`)
- Modify: `lib/engram/notes/note.ex` + `lib/engram/attachments/attachment.ex` — add `field :basename_hmac, :binary`
- Test: extend `test/engram/links_test.exs` + one assertion in the notes upsert tests

**Interfaces:**
- Produces: every code path that writes `path_hmac` ALSO writes `basename_hmac: Crypto.hmac_field(filter_key, Links.basename_key(path))`. Rename recomputes it (it already recomputes `path_hmac` — same seam).

- [ ] **Step 1: Failing test** — in `test/engram/links_test.exs`:

```elixir
test "upsert_note stamps basename_hmac", %{user: user, vault: vault} do
  {:ok, _} = Engram.Notes.upsert_note(user, vault, %{
    "path" => "Deep/Cased NAME.md", "content" => "x", "mtime" => 1_000.0
  })
  {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
  expected = Engram.Crypto.hmac_field(filter_key, "cased name")

  {:ok, [note]} = Repo.with_tenant(user.id, fn -> Repo.all(Engram.Notes.Note) end)
  assert note.basename_hmac == expected
end
```

- [ ] **Step 2: Verify FAIL** (`basename_hmac` nil).
- [ ] **Step 3: Implement** — grep EVERY writer: `grep -n 'path_hmac:' lib/engram/notes.ex lib/engram/attachments*.ex lib/engram/**/*.ex`. Each map that sets `path_hmac:` from a plaintext path gains a sibling `basename_hmac:` (the plaintext path is in scope at all of them — that's why this seam and not a trigger). Rename path: `do_rename_note_inner/5` writes new `path_hmac` → add `basename_hmac`. Do NOT forget `batch_upsert_notes` (`:2337`) and `inject_phase_b_fields` (`:4371`) / CRDT checkpoint delegate (`inject_phase_b_fields_pub/6`).
- [ ] **Step 4: Run** `mix test test/engram/links_test.exs test/engram/notes*` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): stamp basename_hmac on all path writers"`

---

### Task 5: Indexing integration

**Files:**
- Modify: `lib/engram/indexing.ex` — `prepare_index/2` (`:56`), `commit_index/1` (`:102`), `index_note/2` (`:36`)
- Test: `test/engram/indexing_links_test.exs`

**Interfaces:**
- Consumes: `Parser.extract/1`, `Links.replace_links/4`.
- Produces: `index_note/2` extracts+persists links on every run, INCLUDING when `chunks == []` (the `{:ok, :no_chunks}` short-circuit at `prepare_index/2:59` must still clear stale links).

- [ ] **Step 1: Failing tests**

```elixir
defmodule Engram.IndexingLinksTest do
  use Engram.DataCase, async: false  # indexing tests hit Qdrant stubs; mirror indexing_test.exs setup

  alias Engram.Links.NoteLink

  # Mirror the setup used in test/engram/indexing_test.exs (Qdrant stub / vault fixture).

  test "index_note persists extracted links" do
    # build user/vault/notes as in indexing_test.exs, target "B.md", source content "[[B]]"
    # run Engram.Indexing.index_note(decrypted_source, vault)
    # assert one NoteLink row, target bound to B
  end

  test "emptying a note clears its links (no_chunks path)" do
    # index source with "[[B]]" -> 1 link; re-index with content "" -> 0 links
  end
end
```

Write these fully by copying the setup from `test/engram/indexing_test.exs` — the fixtures there already produce decrypted notes suitable for `index_note/2`.

- [ ] **Step 2: Verify FAIL.**
- [ ] **Step 3: Implement** — in `prepare_index/2`, extract BEFORE the `chunks == []` branch:

```elixir
link_rows = Engram.Links.Parser.extract(note.content || "")
```

Return it in both branches: change `{:ok, :no_chunks}` to `{:ok, {:no_chunks, link_rows}}` and add `links: link_rows` to the prepared map (`:318`). In `commit_index/1`, after the chunk delete+insert (`:112-114`):

```elixir
:ok = Engram.Links.replace_links(user, vault, note.id, prepared.links)
```

⚠️ `commit_index/1` currently receives only `%{note:, chunk_rows:, qdrant_points:}` — user/vault must ride in the prepared map too (add `user:`/`vault:` where `build_prepared/6` has them in scope). In `index_note/2:38`, handle the new `{:ok, {:no_chunks, link_rows}}` by calling `Links.replace_links(user, vault, note.id, link_rows)` before returning `{:ok, 0}`. Update ALL existing callers/pattern-matches of `{:ok, :no_chunks}` (grep for it).

- [ ] **Step 4: Run** — `mix test test/engram/indexing_links_test.exs test/engram/indexing_test.exs test/engram/indexing_keyword_test.exs` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): extract+persist edges in the index pass"`

---

### Task 6: Lifecycle hooks — create/rename/delete

**Files:**
- Create: `lib/engram/workers/rebind_note_links.ex` (small Oban worker, queue `:indexing`)
- Modify: `lib/engram/notes.ex` — upsert create branch (`:426` area), rename (`do_rename_note_inner/5` ~`:1841`), resurrect (`genesis_resurrect/4` ~`:921`)
- Modify: `lib/engram/workers/delete_note_index.ex` — call `Links.on_note_soft_deleted/2`
- Test: `test/engram/links_lifecycle_test.exs`

**Interfaces:**
- Produces: `Engram.Workers.RebindNoteLinks.new(%{"user_id" => ..., "vault_id" => ..., "basename_key" => ...})` — runs `Links.bind_danglers_for/3`. Enqueued on note CREATE, RENAME (both old and new basename keys — the old name's remaining candidates must re-resolve too), and RESURRECT. Delete flips edges via `DeleteNoteIndex`.

- [ ] **Step 1: Failing tests** — end-to-end through the public API (`upsert_note`, `rename_note`, `delete_note`) with `Oban.Testing` draining the `:indexing` queue (see existing `use Oban.Testing, repo: Engram.Repo` examples in `test/engram/workers/`):

```elixir
test "creating the target binds existing danglers", %{user: user, vault: vault} do
  # upsert source with [[Later]]; drain embed/indexing jobs; assert dangling
  # upsert "x/Later.md"; drain; assert bound
end

test "renaming a note re-resolves danglers to its new name", %{user: user, vault: vault} do
  # source links [[Fresh]]; create "Old.md"; rename Old.md -> Fresh.md; drain
  # assert edge bound to that note id
end

test "renaming AWAY re-resolves edges that pointed at the old name", %{user: user, vault: vault} do
  # A.md and b/A.md exist; source links [[A]] (bound to A.md, shortest)
  # rename A.md -> Z.md; drain; assert edge re-bound to b/A.md
end

test "delete flips incoming edges to dangling and drops outgoing", %{user: user, vault: vault} do
  # via Notes.delete_note + drain delete_note_index queue
end
```

- [ ] **Step 2: Verify FAIL.**
- [ ] **Step 3: Implement worker** (model: `delete_note_index.ex` — bare-args worker on queue `:indexing`, `max_attempts: 3`, `RotationGate.check/1` snooze pattern from `embed_note.ex:59-70`):

```elixir
defmodule Engram.Workers.RebindNoteLinks do
  use Oban.Worker, queue: :indexing, max_attempts: 3

  alias Engram.{Accounts, Links, Vaults}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id, "basename_key" => key}}) do
    case Engram.Crypto.RotationGate.check(user_id) do
      :ok ->
        user = Accounts.get_user!(user_id)
        vault = Vaults.get_vault!(user, vault_id)
        Links.bind_danglers_for(user, vault, key)

      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
    end
  end
end
```

(Check the real accessor names for user/vault fetch — mirror whatever `embed_note.ex:243-250` uses.) Hook enqueues: create branch of upsert (only when the note is NEW — the `prev_hash` seam at `notes.ex:426` distinguishes), rename (enqueue TWO jobs: old basename key + new), resurrect. Delete: in `DeleteNoteIndex.perform`, after index cleanup, `Links.on_note_soft_deleted(user_id, note_id)` + enqueue rebind for the deleted note's basename (its danglers-to-be may re-resolve to a case-variant sibling).

- [ ] **Step 4: Run** — `mix test test/engram/links_lifecycle_test.exs` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): lifecycle hooks — create/rename/delete rebinding"`

---

### Task 7: DEK rotation integration

**Files:**
- Modify: `lib/engram/crypto/user_dek_rotation.ex` — add `sweep_note_links/5` to `run_phases/2` (`:133-145`); extend `rewrap_note_columns/5` (`:897`) and the attachments sweep (`:629`) to also rebuild `basename_hmac` from the decrypted path
- Test: extend `test/engram/crypto/user_dek_rotation_test.exs` (find the existing per-table rotation test and mirror it)

**Interfaces:**
- Consumes: existing `try_rewrap/7`, `sweep_table_loop/4`, `fetch_batch_ids/3` machinery.
- Produces: after `rotate_user/1`, all `note_links` ciphertexts decrypt under the new DEK, `target_basename_hmac` and notes/attachments `basename_hmac` are recomputed with the new filter key, `dek_version` bumped.

- [ ] **Step 1: Failing test** — create user + notes + links (via `Links.replace_links`), run `rotate_user`, assert: `Links.links_for_note/2` still decrypts; `target_basename_hmac` equals `hmac_field(new_filter_key, basename_key(target))`; resolution still works for a NEW link written post-rotation (proves note.basename_hmac was rebuilt).
- [ ] **Step 2: Verify FAIL.**
- [ ] **Step 3: Implement** — `sweep_note_links/5` follows `sweep_attachments/5` (`:394`) structurally; column tuples:

```elixir
[
  {:target_text, :target_text_ciphertext, :target_text_nonce, :target_basename_hmac,
   &Engram.Links.basename_key/1},
  {:alias, :alias_ciphertext, :alias_nonce, nil, nil},
  {:anchor, :anchor_ciphertext, :anchor_nonce, nil, nil}
]
```

with AAD table `:note_links`. The generic `fetch_batch_ids/3` `user_id` fallback (`:882`) covers batching. For notes/attachments: where the `:path` tuple's rewrap computes `path_hmac`, add a second update entry `basename_hmac: Crypto.hmac_field(new_filter_key, Engram.Links.basename_key(plaintext))` — the plaintext path is already in scope at `:937-949`. Also check `lib/engram/crypto/aad_rebind.ex` and `master_rotation.ex` for hardcoded table lists — if they enumerate tables with ciphertext, add `note_links`; if they operate via wrapped-DEK only, no change (read them, decide, note the decision in the commit message).

- [ ] **Step 4: Run** — `mix test test/engram/crypto/` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): register note_links + basename_hmac in DEK rotation"`

---

### Task 8: Backfill worker + mix task

**Files:**
- Create: `lib/engram/workers/backfill_note_links.ex`
- Create: `lib/mix/tasks/engram.backfill_note_links.ex` (mirror `lib/mix/tasks/` sibling for content_hash)
- Test: `test/engram/workers/backfill_note_links_test.exs`

**Interfaces:**
- Consumes: pattern from `Engram.Workers.BackfillContentHashHmac` (queue `:crypto_backfill`, `@batch_size 100`, UUID seek cursor with zero-UUID sentinel, self-re-enqueue on `{:more, last_id}`, `RotationGate.check/1`, per-row failure telemetry).
- Produces: for each live note (per user+vault): stamp `basename_hmac` (notes AND attachments pass), then decrypt content → `Parser.extract` → `Links.replace_links`. Skip filter for resumability: notes pass skips rows where `basename_hmac IS NOT NULL AND` links already exist? NO — links may legitimately be zero. Use `basename_hmac IS NULL` for pass 1 idempotence; pass 2 (links) keys off a `"scope" => "links"` arg and is idempotent by construction (`replace_links` is delete+insert).

- [ ] **Step 1: Failing test** — insert 3 notes with cross-links via `Fixtures.insert_note!` (which does NOT populate links or basename_hmac), run the worker to completion (drain self-re-enqueues via `Oban.Testing`), assert basename_hmacs stamped and edges resolved.
- [ ] **Step 2: Verify FAIL.**
- [ ] **Step 3: Implement** — copy `backfill_content_hash_hmac.ex` structure wholesale; three scopes: `"note_hmacs"`, `"attachment_hmacs"`, `"links"` run in sequence (each scope's `{:done, _}` enqueues the next scope). The links scope decrypts content per note (`Crypto.maybe_decrypt_note_fields/2` — the same call `embed_note.ex:254` makes).
- [ ] **Step 4: Run** — `mix test test/engram/workers/backfill_note_links_test.exs` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): backfill worker (hmacs + edges) + mix task"`

---

### Task 9: API — links in note payload + backlinks endpoint

**Files:**
- Modify: `lib/engram_web/controllers/notes_controller.ex` — `note_json/1` (`:499`), new `backlinks/2` action with `operation(...)`
- Modify: `lib/engram_web/router.ex` — `get "/notes/by-id/:id/backlinks"` BEFORE the `get "/notes/*path"` wildcard (`:382`)
- Modify: `lib/engram_web/schemas/` — add `Schemas.NoteLink`, `Schemas.Backlinks`; extend `Schemas.Note` with `links`
- Test: extend `test/engram_web/controllers/notes_controller_test.exs`

**Interfaces:**
- Produces:
  - `GET /api/notes/by-id/:id` → existing payload + `"links": [{"target_text", "target_note_id", "target_attachment_id", "target_path", "alias", "anchor", "link_type", "dangling"}]`
  - `GET /api/notes/by-id/:id/backlinks` → `{"backlinks": [{"source_note_id", "source_path", "source_title", "alias", "anchor"}]}` (400 invalid UUID / 404 unknown note, mirroring `show_by_id`)

- [ ] **Step 1: Failing controller tests** — mirror the existing `show_by_id` tests' auth/vault setup; assert links appear after indexing a note with `[[refs]]`, backlinks endpoint returns the inverse, cross-user token gets 404 (isolation), invalid UUID 400.
- [ ] **Step 2: Verify FAIL.**
- [ ] **Step 3: Implement** — `note_json/1` gains `links: Links.links_for_note(user, note.id)` — note: `note_json/1` currently takes only `note`; thread `user` (change to `note_json(note, user)`; grep all callers in the controller). `backlinks/2` clones `show_by_id/2`'s `with` chain, then `json(conn, %{backlinks: Links.backlinks_for_note(user, id)})` after confirming the note exists in this vault. OpenAPI: copy `Schemas.Note` structure style for the two new schemas; regenerate the committed `openapi.json` if the repo has a task for it (`grep -rn openapi.json mix.exs lib/mix/tasks/` — follow the api-docs-coverage pipeline doc if the coverage gate complains).
- [ ] **Step 4: Run** — `mix test test/engram_web/controllers/notes_controller_test.exs` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(links): links in note payload + backlinks endpoint"`

---

### Task 10: Gauntlet, PR, backfill-on-deploy note

- [ ] **Step 1: Full gauntlet, SEQUENTIALLY** (concurrent dialyzer starves the DB — 8 fake failures):

```bash
mix format && mix credo --strict && mix dialyzer && mix test --warnings-as-errors
```

- [ ] **Step 2: Check main moved** — `git fetch origin main && git log --oneline HEAD..origin/main`; if commits landed, merge main in and re-run the gauntlet.
- [ ] **Step 3: Push + PR** — title `feat: note_links edge table — extraction, resolution, lifecycle, APIs`; body: `Closes #591`, link the vault spec, list the three migrations; **label `phase/expand`** (CI-required). Do NOT bump mix.exs version.
- [ ] **Step 4: PR description must state the deploy follow-up:** run `mix engram.backfill_note_links` (via release rpc wrapper — Mix.Task is unavailable in releases, so implement the mix task as a thin wrapper over a public `Engram.Links.Backfill.enqueue_all/0` that CAN be called via rpc; see feedback_mix_task_in_release).

---

## Self-review notes (already applied)

- Spec coverage: schema ✓ (T1), parser incl. code-fence exclusion ✓ (T2), resolution rules ✓ (T3), lifecycle matrix ✓ (T3/T6), rotation ✓ (T7), backfill ✓ (T8), APIs ✓ (T9). Frontend rewire + `[[` autocomplete are a SEPARATE plan after this PR lands.
- `{:ok, :no_chunks}` short-circuit and rename-doesn't-index gotchas are explicitly handled (T5/T6) — these came from code inspection, not the spec.
- Type consistency: `Links.basename_key/1`, `Links.replace_links/4`, `Parser.extract/1` signatures used identically across tasks.
