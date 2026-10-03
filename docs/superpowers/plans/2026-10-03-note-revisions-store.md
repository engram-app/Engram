# Note Revisions Store (#1710) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record an exact, per-actor version history of every note's text, with metadata in Postgres and compressed, encrypted text blobs in object storage.

**Architecture:** A transactional outbox. Inside each content write's own transaction, right after its fenced `UPDATE` succeeds, `Engram.Notes.Revisions.record_write/4` decides whether this save starts a new version. If it does, it copies the note's OLD `content_ciphertext` into the closing version's row (no decrypt, no S3). After commit, `Engram.Notes.ContentCommit.after_commit/3` enqueues `Engram.Workers.FinalizeRevision`, which decrypts the copy, gzips it, re-encrypts it under revision AAD, stores it through `Engram.Storage`, and clears the copy. The open version has no copy anywhere: its text is the note.

**Tech Stack:** Elixir 1.17 / OTP 27, Phoenix, Ecto + Postgres 18 (FORCE RLS), Oban 2.24, `Engram.Storage` (S3 / bytea / `InMemory` in tests), AES-GCM `Engram.Crypto.Envelope`, stdlib `:zlib`.

**Spec:** Engram vault, `50 Engineering/_Superpowers Specs/2026-10-03-note-revisions-store-design.md`. Read v2 and the **v2.1 corrections** at the bottom; v2.1 wins wherever they disagree.

## Global Constraints

- Every `mix` command and every `git push` runs as `mise exec -- ...` (the PATH `erl` is OTP 26; the repo needs 27).
- The PR carries the label `phase/expand` (new table only).
- The new table copies `priv/repo/migrations/20260816070000_create_vault_index_update_log_expand.exs`: `# squawk-ignore-file`, `ENABLE` + `FORCE` RLS, a tenant policy in the `(SELECT current_setting('app.current_tenant', true))` form, `engram_app` grants. Plus a `maintenance_all` policy and an entry in `Engram.Repo`'s `@tenant_tables`.
- **History must never fail a save.** Every statement in `record_write/4` runs with `mode: :savepoint`, and any failure is logged and swallowed at that one boundary.
- **`record_write/4` runs only AFTER a successful fenced write, in the same transaction.** A losing fenced write does not abort its transaction (the checkpoint's `update_all` returns `{0, _}`; `lookup_and_write` retries inside the same transaction).
- No plaintext in Oban args, log lines, or storage keys. On content-path modules, log `Metadata.safe_reason/1` / `Metadata.safe_exit_reason/1`, never `Exception.message/1` or `inspect/1` of a term (`Engram.Logger.LogCallComplianceTest` enforces this).
- Storage key: `revisions/<user_id>/<vault_id>/<note_id>/<revision_id>`, built only by `Engram.Storage.revision_key/4`.
- Blob: `Envelope.encrypt(:zlib.gzip(text), dek, Crypto.aad_for_row(:note_revisions, :content, revision_id))`. The nonce goes in the `blob_nonce` column.
- Session gap: `Application.get_env(:engram, :history_session_gap_minutes, 10)`.
- Kill switch: `Application.get_env(:engram, :history_recording, false)`. On in dev/test. Prod reads `HISTORY_RECORDING` and stays off until #1713 and #1715 ship.
- Limit key: only `history_enabled` (boolean, true for every tier), read through `Engram.Billing.granted?/2`.
- Actors: `"sync"`, `"mcp"`, `"api:<api_key_id>"`, `"import"`, `"link_rewrite"`, `"maintenance"`. A caller that passes none gets `"api"`, so a forgotten site still splits from your typing rather than merging into it.
- No version bumps (release-please owns them). Conventional commits. Before pushing: `mix format`, `mix credo --strict`, `mix dialyzer`, and the FULL `mix test` (CI-only lints live in the full suite).

## Review Focus

1. **A losing fenced write records nothing.** The checkpoint's `{0, _}` arm and `lookup_and_write`'s in-transaction retry both commit the surrounding transaction, so a hook placed before the write would persist a version for a save that never happened. Expected: exactly one chain, one open version, no duplicate baseline. Pinned by Task 6's interleave test.
2. **A history failure does not fail or poison the save.** Expected: the note write commits and a later statement in the same transaction still runs. Pinned by Task 2's "failure does not poison the transaction" test.
3. **Two finalizes for one version never strand the blob.** `Oban.insert_all` (batch, sweep) bypasses `unique`, so two runs can race. Without the advisory lock each PUTs under the same key with its own nonce and only one nonce reaches the row. Expected: the stored blob decrypts with the row's `blob_nonce`. Pinned by Task 3's real-connection test.
4. **An empty prior note produces no baseline** (genesis, a just-created empty note). Expected: an open row only. Pinned by Task 2.
5. **Switched off means silent.** With `history_recording` false, or `history_enabled` false for the user, nothing is written. Pinned by Task 2.

## File Map

Create:
- `priv/repo/migrations/20261003120000_create_note_revisions_expand.exs`: the table, indexes, RLS
- `lib/engram/notes/revision.ex`: schema and changesets
- `lib/engram/notes/revisions.ex`: `record_write/4`, `decrypt_pending/2`, `recording?/1`
- `lib/engram/notes/content_commit.ex`: `after_commit/3`, the single post-commit hook for single-note content writes
- `lib/engram/workers/finalize_revision.ex`: outbox copy to blob
- `lib/engram/workers/finalize_revision_sweep.ex`: hourly re-enqueue of stranded copies
- `lib/engram_web/write_actor.ex`: `for_conn/1`
- `docs/context/note-revisions-history.md`
- Tests: `test/engram/notes/revision_schema_test.exs`, `test/engram/notes/revisions_test.exs`, `test/engram/workers/finalize_revision_test.exs`, `test/engram/notes/content_commit_test.exs`, `test/engram/notes/revisions_write_path_test.exs`, `test/engram/notes/revisions_interleave_test.exs`, `test/engram/workers/finalize_revision_sweep_test.exs`, `test/engram_web/write_actor_test.exs`, `test/engram/mcp/handlers_write_actor_test.exs`

Modify:
- `lib/engram/repo.ex`: `@tenant_tables`
- `lib/engram/billing/limit_keys.ex` and `test/engram/billing/limit_keys_test.exs`
- `config/config.exs`, `config/runtime.exs`
- `lib/engram/storage.ex`
- `lib/engram/notes/crdt_checkpoint.ex`
- `lib/engram/notes.ex`
- `lib/engram/mcp/handlers.ex`, `lib/engram_web/controllers/notes_controller.ex`, `lib/engram/links/rewriter.ex`, `lib/engram/notes/utf8_backfill.ex`
- `test/engram/oban_cron_test.exs`
- `AGENTS.md`

---

### Task 1: The `note_revisions` table, schema and RLS

**Files:**
- Create: `priv/repo/migrations/20261003120000_create_note_revisions_expand.exs`
- Create: `lib/engram/notes/revision.ex`
- Modify: `lib/engram/repo.ex` (the `@tenant_tables` line, currently line 16)
- Test: `test/engram/notes/revision_schema_test.exs`

**Interfaces:**
- Produces: `Engram.Notes.Revision` with `open_changeset/1` and `closed_copy_changeset/1`. Unique index `note_revisions_one_open_per_note`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/notes/revision_schema_test.exs
defmodule Engram.Notes.RevisionSchemaTest do
  @moduledoc """
  `note_revisions` is a tenant table (#1710). The suite connects as a
  superuser, which bypasses RLS, so a scoped read that comes back green proves
  nothing on its own. The CONTROL test is what makes the others mean anything:
  it shows the role drop actually engaged. See
  docs/context/rls-enforcement-testing-traps.md.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Notes.Revision
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "History.md"})

    {:ok, rev} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(Revision.open_changeset(open_attrs(user, vault, note)))
      end)

    %{user: user, vault: vault, note: note, rev: rev}
  end

  defp open_attrs(user, vault, note) do
    %{
      note_id: note.id,
      user_id: user.id,
      vault_id: vault.id,
      actor: "sync",
      origin: "edit",
      session_started_at: DateTime.utc_now()
    }
  end

  defp count_query(rev), do: from(r in Revision, where: r.id == ^rev.id, select: count(r.id))

  test "control: with no tenant set, the app role sees nothing", %{rev: rev} do
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.one(count_query(rev), skip_tenant_check: true) end)
  end

  test "the owning tenant sees its version", %{user: user, rev: rev} do
    assert {:returned, {:ok, 1}} =
             as_prod_role(fn -> Repo.with_tenant(user.id, fn -> Repo.one(count_query(rev)) end) end)
  end

  test "another tenant does not", %{rev: rev} do
    {:ok, other} = Engram.Fixtures.user_with_dek_fixture()

    assert {:returned, {:ok, 0}} =
             as_prod_role(fn -> Repo.with_tenant(other.id, fn -> Repo.one(count_query(rev)) end) end)
  end

  # The note-row write fence already serializes saves to one note. This index
  # is the backstop: if a future save path forgets the fence, Postgres refuses
  # the second open version instead of quietly storing two.
  test "a note can have only one open version", %{user: user, vault: vault, note: note} do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert(Revision.open_changeset(open_attrs(user, vault, note)))
      end)

    assert {:error, %Ecto.Changeset{errors: errors}} = result

    assert {_, [constraint: :unique, constraint_name: "note_revisions_one_open_per_note"]} =
             errors[:note_id]
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/engram/notes/revision_schema_test.exs`
Expected: compile error, `Engram.Notes.Revision.__struct__/1 is undefined`.

- [ ] **Step 3: Write the migration**

```elixir
# priv/repo/migrations/20261003120000_create_note_revisions_expand.exs
defmodule Engram.Repo.Migrations.CreateNoteRevisionsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand: new table, no backfill. Note version history (#1710, epic #609).
  #
  # One row per version, meaning one editing session by one actor. A row is
  # OPEN while `closed_at` is NULL, and the open version has no copy of its text
  # anywhere: its text is the note. When a later save starts a new version, that
  # save closes this row and copies the note's OLD content ciphertext into
  # `pending_*` in its own transaction (an outbox). FinalizeRevision moves the
  # copy to object storage and clears it.
  #
  # RLS mirrors vault_index_update_log: tenant-scoped on user_id, ENABLE +
  # FORCE, engram_app grants, plus the maintenance_all policy every tenant table
  # needs (Engram.Repo.MaintenanceRoleTest fails without it).
  def change do
    create table(:note_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false

      add :actor, :text, null: false
      add :origin, :text, null: false
      # Unused until teams. One nullable column now beats a migration on a
      # large table later.
      add :actor_user_id, :uuid
      add :restored_from_id, references(:note_revisions, type: :uuid, on_delete: :nilify_all)

      add :session_started_at, :timestamptz, null: false
      add :closed_at, :timestamptz

      # The outbox copy: the note's own content ciphertext, still bound to the
      # notes AAD of note_id. Set when the version closes, cleared by
      # FinalizeRevision.
      add :pending_ciphertext, :binary
      add :pending_nonce, :binary
      add :pending_dek_version, :integer

      add :storage_key, :text
      add :blob_nonce, :binary
      add :content_hash, :text
      add :char_count, :integer
      add :dek_version, :integer, null: false, default: 2

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:note_revisions, [:note_id],
             where: "closed_at IS NULL",
             name: :note_revisions_one_open_per_note
           )

    create index(:note_revisions, [:note_id, :inserted_at])

    create index(:note_revisions, [:updated_at],
             where: "pending_ciphertext IS NOT NULL",
             name: :note_revisions_pending
           )

    # RLS predicate, and the on_delete cascades scan it.
    create index(:note_revisions, [:user_id])

    execute(
      "ALTER TABLE note_revisions ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE note_revisions DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE note_revisions FORCE ROW LEVEL SECURITY",
      "ALTER TABLE note_revisions NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_note_revisions ON note_revisions
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_note_revisions ON note_revisions"
    )

    execute(
      "CREATE POLICY maintenance_all ON note_revisions TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON note_revisions"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON note_revisions TO engram_app",
      "REVOKE ALL ON note_revisions FROM engram_app"
    )
  end
end
```

- [ ] **Step 4: Write the schema**

```elixir
# lib/engram/notes/revision.ex
defmodule Engram.Notes.Revision do
  @moduledoc """
  One version of a note: an editing session by one actor (#1710, epic #609).

  A row is OPEN while `closed_at` is nil. The open version has no copy of its
  text anywhere, because its text IS the note. When a later save starts a new
  version, `Engram.Notes.Revisions.record_write/4` closes this row and copies
  the note's old content ciphertext into `pending_*`, in the same transaction
  as that save. `Engram.Workers.FinalizeRevision` then moves the copy into
  `Engram.Storage` and clears `pending_*`.
  """
  use Engram.Schema
  import Ecto.Changeset

  @origins ~w(edit baseline restore import)

  schema "note_revisions" do
    field :note_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :actor, :string
    field :origin, :string
    field :actor_user_id, Ecto.UUID
    field :restored_from_id, Ecto.UUID
    field :session_started_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :pending_ciphertext, :binary, redact: true
    field :pending_nonce, :binary, redact: true
    field :pending_dek_version, :integer
    field :storage_key, :string
    field :blob_nonce, :binary
    field :content_hash, :string
    field :char_count, :integer
    field :dek_version, :integer, default: 2

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(note_id user_id vault_id actor origin session_started_at)a
  @copy ~w(closed_at pending_ciphertext pending_nonce pending_dek_version)a

  @doc "A new open version."
  def open_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:origin, @origins)
    |> unique_constraint(:note_id, name: :note_revisions_one_open_per_note)
  end

  @doc "A version born closed, carrying an outbox copy. Used for the baseline."
  def closed_copy_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @copy ++ [:content_hash])
    |> validate_required(@required ++ @copy)
    |> validate_inclusion(:origin, @origins)
  end
end
```

- [ ] **Step 5: Register the tenant table**

In `lib/engram/repo.ex`, append `note_revisions` to `@tenant_tables`:

```elixir
  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements onboarding_actions crdt_update_log note_links vault_index_states vault_index_update_log account_exports note_revisions)a
```

- [ ] **Step 6: Run the test and the tenant-table suites**

Run: `mise exec -- mix test test/engram/notes/revision_schema_test.exs test/engram/repo/maintenance_role_test.exs test/engram/rls_policy_form_test.exs test/engram/repo_tenant_guard_test.exs test/lint/migration_rls_lint_test.exs`
Expected: all PASS. If `rls_policy_form_test` fails, diff the policy text against `vault_index_update_log`'s and match it exactly. Then run `mise exec -- bash priv/repo/lint_migrations.sh` and expect it to be clean.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20261003120000_create_note_revisions_expand.exs lib/engram/notes/revision.ex lib/engram/repo.ex test/engram/notes/revision_schema_test.exs
git commit -m "feat(history): add the note_revisions table"
```

---

### Task 2: `Revisions.record_write/4`, the in-transaction version decision

**Files:**
- Create: `lib/engram/notes/revisions.ex`
- Modify: `lib/engram/billing/limit_keys.ex`, `test/engram/billing/limit_keys_test.exs`, `config/config.exs`, `config/runtime.exs`
- Test: `test/engram/notes/revisions_test.exs`

**Interfaces:**
- Consumes: `Engram.Notes.Revision` (Task 1).
- Produces:
  - `Engram.Notes.Revisions.record_write(existing :: %Engram.Notes.Note{}, user :: %Engram.Accounts.User{}, actor :: String.t(), now :: DateTime.t() \\ DateTime.utc_now()) :: :ok | :skipped | :error`. It must be called inside the caller's tenant transaction, AFTER the fenced write succeeded. `existing` is the PRE-write row.
  - `Engram.Notes.Revisions.decrypt_pending(%Revision{}, %User{}) :: {:ok, String.t()} | {:error, term()}`
  - `Engram.Notes.Revisions.recording?(%User{}) :: boolean()`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/notes/revisions_test.exs
defmodule Engram.Notes.RevisionsTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{Note, Revision, Revisions}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Revisions", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp create(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    raw(user, note.id)
  end

  defp raw(user, id), do: tenant(user, fn -> Repo.get!(Note, id) end)

  defp record(user, existing, actor, now),
    do: tenant(user, fn -> Revisions.record_write(existing, user, actor, now) end)

  defp revisions(user, note_id),
    do: tenant(user, fn -> Repo.all(from(r in Revision, where: r.note_id == ^note_id)) end)

  defp tenant(user, fun) do
    {:ok, value} = Repo.with_tenant(user.id, fun)
    value
  end

  defp open(revs), do: Enum.find(revs, &is_nil(&1.closed_at))
  defp text_of(user, rev), do: elem(Revisions.decrypt_pending(rev, user), 1)

  test "first write: a baseline holds the old text, and a version opens", %{user: u, vault: v} do
    existing = create(u, v, "a.md", "original text")

    assert :ok = record(u, existing, "sync", DateTime.utc_now())

    revs = revisions(u, existing.id)
    baseline = Enum.find(revs, &(&1.origin == "baseline"))
    assert baseline.closed_at
    assert text_of(u, baseline) == "original text"
    assert %Revision{actor: "sync", origin: "edit"} = open(revs)
    assert length(revs) == 2
  end

  test "an empty note gets no baseline", %{user: u, vault: v} do
    existing = create(u, v, "empty.md", "")

    assert :ok = record(u, existing, "sync", DateTime.utc_now())

    assert [%Revision{closed_at: nil, actor: "sync"}] = revisions(u, existing.id)
  end

  test "same actor inside the gap changes nothing", %{user: u, vault: v} do
    existing = create(u, v, "gap.md", "one")
    t0 = existing.updated_at
    :ok = record(u, existing, "sync", t0)

    :ok = record(u, %{existing | updated_at: t0}, "sync", DateTime.add(t0, 599, :second))

    assert length(revisions(u, existing.id)) == 2
  end

  test "same actor past the gap closes the version and opens another", %{user: u, vault: v} do
    existing = create(u, v, "gap2.md", "one")
    t0 = existing.updated_at
    :ok = record(u, existing, "sync", t0)
    first_open = open(revisions(u, existing.id))

    :ok = record(u, %{existing | updated_at: t0}, "sync", DateTime.add(t0, 601, :second))

    revs = revisions(u, existing.id)
    closed = Enum.find(revs, &(&1.id == first_open.id))
    assert closed.closed_at
    assert text_of(u, closed) == "one"
    assert open(revs).id != first_open.id
  end

  test "a different actor closes your version with the exact text it replaced",
       %{user: u, vault: v} do
    existing = create(u, v, "ai.md", "draft")
    :ok = record(u, existing, "sync", DateTime.utc_now())
    yours = open(revisions(u, existing.id))

    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "ai.md", "content" => "what you typed"})
    before_ai = raw(u, existing.id)

    :ok = record(u, before_ai, "mcp", DateTime.utc_now())

    revs = revisions(u, existing.id)
    closed = Enum.find(revs, &(&1.id == yours.id))
    assert text_of(u, closed) == "what you typed"
    assert %Revision{actor: "mcp"} = open(revs)
  end

  test "recording switched off writes nothing", %{user: u, vault: v} do
    previous = Application.get_env(:engram, :history_recording)
    Application.put_env(:engram, :history_recording, false)
    on_exit(fn -> Application.put_env(:engram, :history_recording, previous) end)

    existing = create(u, v, "off.md", "text")

    assert :skipped = record(u, existing, "sync", DateTime.utc_now())
    assert revisions(u, existing.id) == []
  end

  test "history_enabled false for the user writes nothing", %{user: u, vault: v} do
    insert(:user_limit_override, user: u, key: "history_enabled", value: %{"v" => false})
    existing = create(u, v, "denied.md", "text")

    assert :skipped = record(u, existing, "sync", DateTime.utc_now())
    assert revisions(u, existing.id) == []
  end

  # History must never fail a save. A note id that does not exist makes the
  # baseline INSERT violate its foreign key; the savepoint absorbs it, and a
  # later statement in the SAME transaction still runs.
  test "a failure does not poison the caller's transaction", %{user: u, vault: v} do
    existing = create(u, v, "fk.md", "text")
    orphan = %{existing | id: Ecto.UUID.generate()}

    {:ok, {result, count}} =
      Repo.with_tenant(u.id, fn ->
        result = Revisions.record_write(orphan, u, "sync", DateTime.utc_now())
        {result, Repo.one(from(n in Note, select: count(n.id)))}
      end)

    assert result == :error
    assert count >= 1
  end
end
```

Also, in `test/engram/billing/limit_keys_test.exs`, update the catalog-count test:

```elixir
    test "returns the 27 catalog keys" do
      keys = LimitKeys.all()
      assert length(keys) == 27
      assert :notes_cap in keys
      assert :vaults_cap in keys
      assert :reranker_enabled in keys
      assert :cross_vault_search in keys
      assert :history_enabled in keys
    end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram/notes/revisions_test.exs test/engram/billing/limit_keys_test.exs`
Expected: compile error (`Engram.Notes.Revisions` undefined) and a count failure (26 != 27).

- [ ] **Step 3: Add the limit key**

In `lib/engram/billing/limit_keys.ex`, inside `@catalog`, next to `attachments_enabled`:

```elixir
    # Note version history (#1710). Grant-shaped (true = the user gets it),
    # per the polarity rule this file's tests pin. Every tier has history, so
    # this is a kill switch per tier or per user, gated in
    # Engram.Notes.Revisions.recording?/1. The retention keys
    # (history_max_versions, history_retention_days) land with their
    # enforcement in #1712: a catalog row without a gate is the dead-entry
    # pattern limit_keys_test.exs refuses.
    history_enabled: %{type: :boolean, defaults: %{free: true, starter: true, pro: true}},
```

- [ ] **Step 4: Add the config**

In `config/config.exs`, near the other `config :engram, :...` application settings (not inside the Oban block):

```elixir
# Note version history (#1710). On in dev and test. Prod reads
# HISTORY_RECORDING in runtime.exs and stays OFF until #1713 (DEK rotation
# covers note_revisions) and #1715 (the orphan sweep walks revisions/) ship:
# before #1713 a key rotation would make stored versions undecryptable, and
# before #1715 a deleted account's blobs would stay in storage.
config :engram, :history_recording, true
config :engram, :history_session_gap_minutes, 10
```

At the end of `config/runtime.exs`:

```elixir
# Note version history (#1710). See config.exs for why prod defaults off.
if config_env() == :prod do
  config :engram, :history_recording, System.get_env("HISTORY_RECORDING", "false") == "true"
end

if gap = System.get_env("HISTORY_SESSION_GAP_MINUTES") do
  config :engram, :history_session_gap_minutes, String.to_integer(gap)
end
```

- [ ] **Step 5: Write `Revisions`**

```elixir
# lib/engram/notes/revisions.ex
defmodule Engram.Notes.Revisions do
  @moduledoc """
  The version-history write path (#1710, epic #609).

  `record_write/4` runs inside a content write's own transaction, right after
  that write's fenced UPDATE succeeded, and decides whether the save starts a
  new version. A new version starts when a different actor writes, when more
  than the session gap has passed since the note's last edit, or on the note's
  first save after history shipped.

  When it does, the version being closed gets a copy of the note's OLD content
  ciphertext (the outbox). Nothing is decrypted, and nothing touches storage:
  it is bytes moving between two rows. `Engram.Workers.FinalizeRevision` moves
  the copy to storage after commit.

  ## Why after the write, not before

  A losing fenced write does not abort its transaction. The checkpoint's
  `update_all` returns `{0, _}` and the transaction commits, and
  `Notes.lookup_and_write` retries INSIDE the same transaction. A history step
  placed before the write would commit a version for a save that never
  happened. After a successful UPDATE the note row is locked until commit, so
  concurrent saves to one note serialize behind it, history step included.

  ## History never fails a save

  Every statement runs with `mode: :savepoint`, so a failure rolls back only
  itself and leaves the caller's transaction usable. The function-level rescue
  logs and returns `:error`. That is a deliberate isolation boundary, not a
  silent swallow: losing one history entry is the right trade against losing
  the user's write, and the log line says so on its own key.
  """
  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Note, Revision}
  alias Engram.Repo

  require Logger

  @savepoint [mode: :savepoint]

  @doc "True when history is recorded for `user`: the global switch AND the tier key."
  @spec recording?(User.t()) :: boolean()
  def recording?(%User{} = user) do
    Application.get_env(:engram, :history_recording, false) and
      Billing.granted?(user, :history_enabled)
  end

  @doc """
  Record a content write. Call inside the write's transaction, AFTER its fenced
  UPDATE succeeded. `existing` is the PRE-write row: its `content_ciphertext`
  is the text being replaced.
  """
  @spec record_write(Note.t(), User.t(), String.t(), DateTime.t()) :: :ok | :skipped | :error
  def record_write(%Note{} = existing, %User{} = user, actor, now \\ DateTime.utc_now())
      when is_binary(actor) do
    if recording?(user), do: do_record_write(existing, actor, now), else: :skipped
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      Logger.error(
        "history record_write failed note_id=#{existing.id} err=#{Metadata.safe_reason(e)} " <>
          "at=#{Metadata.format_location(__STACKTRACE__)}",
        Metadata.with_category(:error, :sync, note_id: existing.id)
      )

      :error
  end

  defp do_record_write(existing, actor, now) do
    case open_version(existing.id) do
      %Revision{actor: ^actor} = open ->
        if within_gap?(existing.updated_at, now),
          do: :ok,
          else: close_and_open(open, existing, actor, now)

      %Revision{} = open ->
        close_and_open(open, existing, actor, now)

      nil ->
        first_or_orphaned(existing, actor, now)
    end
  end

  # No open version. Either the note has no history at all (first save after
  # history shipped: keep a baseline of the text being replaced), or a later
  # issue left history without an open row (#1711 restore, #1712 prune). In
  # the second case still keep the text being replaced rather than lose it.
  defp first_or_orphaned(existing, actor, now) do
    copy_result =
      cond do
        not has_content?(existing) -> :ok
        any_history?(existing.id) -> insert_closed_copy(existing, "edit", actor, now)
        true -> insert_closed_copy(existing, "baseline", "baseline", now)
      end

    with :ok <- copy_result, do: insert_open(existing, actor, now)
  end

  defp close_and_open(open, existing, actor, now) do
    query = from(r in Revision, where: r.id == ^open.id and is_nil(r.closed_at))
    set = [closed_at: now, updated_at: now] ++ Map.to_list(copy_of(existing))

    case Repo.update_all(query, [set: set], @savepoint) do
      {1, _} -> insert_open(existing, actor, now)
      {0, _} -> refused(existing.id)
    end
  end

  defp insert_open(existing, actor, now) do
    %{
      note_id: existing.id,
      user_id: existing.user_id,
      vault_id: existing.vault_id,
      actor: actor,
      origin: origin_for(actor),
      session_started_at: now
    }
    |> Revision.open_changeset()
    |> insert(existing.id)
  end

  defp insert_closed_copy(existing, origin, actor, now) do
    %{
      note_id: existing.id,
      user_id: existing.user_id,
      vault_id: existing.vault_id,
      actor: actor,
      origin: origin,
      session_started_at: existing.updated_at || now,
      closed_at: now
    }
    |> Map.merge(copy_of(existing))
    |> Revision.closed_copy_changeset()
    |> insert(existing.id)
  end

  defp insert(changeset, note_id) do
    case Repo.insert(changeset, @savepoint) do
      {:ok, _} -> :ok
      {:error, _changeset} -> refused(note_id)
    end
  end

  defp refused(note_id) do
    Logger.error(
      "history version refused note_id=#{note_id}",
      Metadata.with_category(:error, :sync, note_id: note_id)
    )

    :error
  end

  defp open_version(note_id) do
    Repo.one(from(r in Revision, where: r.note_id == ^note_id and is_nil(r.closed_at)), @savepoint)
  end

  defp any_history?(note_id) do
    Repo.exists?(from(r in Revision, where: r.note_id == ^note_id), @savepoint)
  end

  # The outbox copy: the note's own ciphertext, still bound to the notes AAD of
  # note_id, plus the AAD-format marker needed to decrypt it later.
  defp copy_of(existing) do
    %{
      pending_ciphertext: existing.content_ciphertext,
      pending_nonce: existing.content_nonce,
      pending_dek_version: existing.dek_version,
      content_hash: existing.content_hash
    }
  end

  # An empty note encrypts to the bare AEAD tag. There is nothing to go back to.
  defp has_content?(%Note{content_ciphertext: ct}) when is_binary(ct),
    do: byte_size(ct) > Envelope.tag_bytes()

  defp has_content?(_), do: false

  defp within_gap?(%DateTime{} = last, now),
    do: DateTime.diff(now, last, :second) <= session_gap_seconds()

  defp within_gap?(_, _now), do: false

  defp session_gap_seconds,
    do: Application.get_env(:engram, :history_session_gap_minutes, 10) * 60

  defp origin_for("import"), do: "import"
  defp origin_for("restore"), do: "restore"
  defp origin_for(_actor), do: "edit"

  @doc """
  Decrypt a version's outbox copy. It is the note's own ciphertext, so it
  decrypts exactly as `notes.content` would: notes AAD of note_id when the
  copied row was AAD-bound, empty AAD for a legacy row.
  """
  @spec decrypt_pending(Revision.t(), User.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt_pending(
        %Revision{pending_ciphertext: ct, pending_nonce: nonce, pending_dek_version: v} = rev,
        %User{} = user
      )
      when is_binary(ct) and is_binary(nonce) and is_integer(v) do
    aad =
      if v >= Crypto.row_version_aad_bound(),
        do: Crypto.aad_for_row(:notes, :content, rev.note_id),
        else: <<>>

    with {:ok, dek} <- Crypto.get_dek(user) do
      case Envelope.decrypt(ct, nonce, dek, aad) do
        {:ok, text} -> {:ok, text}
        :error -> {:error, :decrypt_failed}
      end
    end
  end

  def decrypt_pending(%Revision{}, _user), do: {:error, :nothing_pending}
end
```

- [ ] **Step 6: Run the tests**

Run: `mise exec -- mix test test/engram/notes/revisions_test.exs test/engram/billing/`
Expected: PASS. If a `test/engram/billing/` test enumerates every catalog key (for example `capabilities_test.exs` or `limit_enforcement_test.exs`), it fails on the new key. Add `history_enabled` to its expected set deliberately. That is exactly the edit those tests exist to force.

- [ ] **Step 7: Commit**

```bash
git add lib/engram/notes/revisions.ex lib/engram/billing/limit_keys.ex config/config.exs config/runtime.exs test/engram/notes/revisions_test.exs test/engram/billing/
git commit -m "feat(history): decide version boundaries inside the write"
```

---

### Task 3: `FinalizeRevision`, from outbox copy to stored blob

**Files:**
- Modify: `lib/engram/storage.ex`
- Create: `lib/engram/workers/finalize_revision.ex`
- Test: `test/engram/workers/finalize_revision_test.exs`

**Interfaces:**
- Consumes: `Revisions.decrypt_pending/2`, `Revisions.record_write/4` (Task 2).
- Produces:
  - `Engram.Storage.revision_key(user_id, vault_id, note_id, revision_id) :: String.t()`
  - `Engram.Workers.FinalizeRevision.new_for_note(note_id, user_id) :: Oban.Job.changeset()`
  - `Engram.Workers.FinalizeRevision.finalize_one(revision_id, %User{}) :: :ok | {:error, term()}`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/workers/finalize_revision_test.exs
defmodule Engram.Workers.FinalizeRevisionTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Storage, Vaults}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Note, Revision, Revisions}
  alias Engram.Workers.FinalizeRevision

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Finalize", Ecto.UUID.generate())

    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "keep me"})
    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, :ok} = Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, user, "sync") end)

    {:ok, baseline} =
      Repo.with_tenant(user.id, fn ->
        Repo.one!(from(r in Revision, where: r.note_id == ^note.id and r.origin == "baseline"))
      end)

    %{user: user, vault: vault, note: note, baseline: baseline}
  end

  defp reload(user, id), do: elem(Repo.with_tenant(user.id, fn -> Repo.get!(Revision, id) end), 1)

  defp blob_text(user, rev, aad_id) do
    {:ok, blob} = Storage.adapter().get(rev.storage_key)
    {:ok, dek} = Crypto.get_dek(user)

    case Envelope.decrypt(blob, rev.blob_nonce, dek, Crypto.aad_for_row(:note_revisions, :content, aad_id)) do
      {:ok, gz} -> {:ok, :zlib.gunzip(gz)}
      :error -> :error
    end
  end

  test "moves the copy into storage and clears it", %{user: u, note: n, baseline: b} do
    assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    rev = reload(u, b.id)
    assert rev.pending_ciphertext == nil
    assert rev.storage_key == Storage.revision_key(u.id, rev.vault_id, n.id, rev.id)
    assert {:ok, "keep me"} = blob_text(u, rev, rev.id)
    assert rev.char_count == String.length("keep me")
  end

  test "a second run changes nothing", %{user: u, note: n, baseline: b} do
    :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})
    first = reload(u, b.id)
    {:ok, blob_before} = Storage.adapter().get(first.storage_key)

    assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    assert reload(u, b.id) == first
    assert {:ok, ^blob_before} = Storage.adapter().get(first.storage_key)
  end

  test "the blob is bound to its own revision id", %{user: u, note: n, baseline: b} do
    :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    assert :error = blob_text(u, reload(u, b.id), Ecto.UUID.generate())
  end

  test "a deleted account is a no-op" do
    assert :ok =
             perform_job(FinalizeRevision, %{note_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()})
  end

  test "new_for_note is unique per note while waiting" do
    note_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    {:ok, _} = Oban.insert(FinalizeRevision.new_for_note(note_id, user_id))
    {:ok, _} = Oban.insert(FinalizeRevision.new_for_note(note_id, user_id))

    assert length(all_enqueued(worker: FinalizeRevision, args: %{note_id: note_id})) == 1
  end
end
```

Add a second file for the race, on real connections (the sandbox serializes everything onto one connection, so it cannot exercise a race):

```elixir
# test/engram/workers/finalize_revision_race_test.exs
defmodule Engram.Workers.FinalizeRevisionRaceTest do
  @moduledoc """
  Two finalizes for one version (Oban.insert_all from the batch path or the
  sweep bypasses `unique`). Without the advisory lock each PUTs under the same
  key with its own nonce and only one nonce reaches the row, leaving the blob
  undecryptable. Real connections via Engram.CheckpointInterleave so the two
  runs genuinely overlap.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo, Storage}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Note, Revision, Revisions}
  alias Engram.Workers.FinalizeRevision

  setup do
    CheckpointInterleave.checkout_real!()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user, id: user_id, email: "finalize-race-#{System.unique_integer([:positive])}@test.com")

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Race", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "two concurrent finalizes leave a blob that decrypts", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "race me"})
    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, :ok} = Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, user, "sync") end)

    rev_id =
      Repo.one!(
        from(r in Revision, where: r.note_id == ^note.id and r.origin == "baseline", select: r.id),
        skip_tenant_check: true
      )

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          CheckpointInterleave.checkout_real!()
          FinalizeRevision.finalize_one(rev_id, user)
        end)
      end

    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 15_000))

    rev = Repo.one!(from(r in Revision, where: r.id == ^rev_id), skip_tenant_check: true)
    {:ok, blob} = Storage.adapter().get(rev.storage_key)
    {:ok, dek} = Crypto.get_dek(user)

    assert {:ok, gz} =
             Envelope.decrypt(blob, rev.blob_nonce, dek, Crypto.aad_for_row(:note_revisions, :content, rev.id))

    assert :zlib.gunzip(gz) == "race me"
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram/workers/finalize_revision_test.exs test/engram/workers/finalize_revision_race_test.exs`
Expected: compile error, `Engram.Workers.FinalizeRevision` undefined.

- [ ] **Step 3: Add the key builder**

In `lib/engram/storage.ex`, edit the first line of `object_key/3`'s `@doc` from "This is the ONLY key builder." to "This is the only key builder for attachments; `revision_key/4` below is the only one for note versions." Then add, after `object_key/3`:

```elixir
  @doc """
  Storage key for a note version's blob (#1710).

  Top-level `revisions/` rather than under `<user_id>/`: S3 lifecycle filters
  only match from the start of a key, and the bucket keeps noncurrent versions,
  so this object class needs its own rule (#1714), the same way `exports/`
  has one. Every segment is a UUID, so no plaintext reaches storage URLs or
  access logs, and `revisions` can never equal a user id, so these keys cannot
  collide with `<user_id>/<vault_id>/objects/...`.

  `Engram.Storage.S3.list_user_prefixes/0` skips this prefix (it is not a
  UUID), so the orphan sweep does not see these blobs until #1715 teaches it to.
  """
  def revision_key(user_id, vault_id, note_id, revision_id)
      when is_binary(user_id) and is_binary(vault_id) and is_binary(note_id) and
             is_binary(revision_id) do
    "revisions/#{user_id}/#{vault_id}/#{note_id}/#{revision_id}"
  end
```

- [ ] **Step 4: Write the worker**

```elixir
# lib/engram/workers/finalize_revision.ex
defmodule Engram.Workers.FinalizeRevision do
  @moduledoc """
  Moves note-version outbox copies into storage (#1710).

  `Engram.Notes.Revisions.record_write/4` closes a version by copying the
  note's old content ciphertext into the row (`pending_*`). This decrypts that
  copy with the notes AAD, gzips it, re-encrypts it bound to the revision id,
  stores it through `Engram.Storage`, and clears the copy.

  One job per note, not per revision: it finalizes every pending copy the note
  holds. That keeps enqueueing free of return-value plumbing out of the write
  transaction. An empty run is one indexed query.

  ## Why the advisory lock

  `Oban.insert_all` (the batch path, the hourly sweep) bypasses `unique`, so
  two runs can race on one version. Each would PUT under the same key with its
  own nonce, and only one nonce would reach the row, leaving the stored blob
  undecryptable. Taking `Repo.advisory_lock!/1` on the revision id, then
  re-reading under it, makes the second run see the copy already cleared.

  The lock is held across the storage PUT, which keeps a tenant transaction
  open for the length of one upload. That is acceptable on the `maintenance`
  queue (worker nodes only, concurrency 2).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 10

  import Ecto.Query

  alias Engram.{Accounts, Crypto, Repo, Storage}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Revision, Revisions}

  @doc "Finalize a note's pending copies a few seconds after the write, collapsing bursts."
  def new_for_note(note_id, user_id) when is_binary(note_id) and is_binary(user_id) do
    new(%{note_id: note_id, user_id: user_id},
      schedule_in: 5,
      unique: [period: 60, keys: [:note_id], states: [:available, :scheduled, :retryable]]
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id, "user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      # The account is gone, and its note_revisions rows cascaded with it.
      nil -> :ok
      user -> finalize_note(note_id, user)
    end
  end

  defp finalize_note(note_id, user) do
    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(r in Revision,
            where: r.note_id == ^note_id and not is_nil(r.pending_ciphertext),
            select: r.id
          )
        )
      end)

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case finalize_one(id, user) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc false
  def finalize_one(revision_id, user) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        Repo.advisory_lock!(revision_id)

        case Repo.get(Revision, revision_id) do
          %Revision{pending_ciphertext: ct} = rev when is_binary(ct) -> upload(rev, user)
          _already_done_or_gone -> :ok
        end
      end)

    result
  end

  defp upload(rev, user) do
    with {:ok, text} <- Revisions.decrypt_pending(rev, user),
         {:ok, dek} <- Crypto.get_dek(user) do
      aad = Crypto.aad_for_row(:note_revisions, :content, rev.id)
      {ct, nonce} = Envelope.encrypt(:zlib.gzip(text), dek, aad)
      key = Storage.revision_key(rev.user_id, rev.vault_id, rev.note_id, rev.id)

      with :ok <- Storage.adapter().put(key, ct, content_type: "application/octet-stream") do
        {1, _} =
          Repo.update_all(from(r in Revision, where: r.id == ^rev.id),
            set: [
              storage_key: key,
              blob_nonce: nonce,
              char_count: String.length(text),
              dek_version: Crypto.row_version_aad_bound(),
              pending_ciphertext: nil,
              pending_nonce: nil,
              pending_dek_version: nil,
              updated_at: DateTime.utc_now()
            ]
          )

        :ok
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `mise exec -- mix test test/engram/workers/finalize_revision_test.exs test/engram/workers/finalize_revision_race_test.exs test/engram/storage_test.exs`
Expected: PASS. If `test/engram/storage_test.exs` doesn't exist, drop it from the command.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/storage.ex lib/engram/workers/finalize_revision.ex test/engram/workers/finalize_revision_test.exs test/engram/workers/finalize_revision_race_test.exs
git commit -m "feat(history): finalize version copies into storage"
```

---

### Task 4: `ContentCommit.after_commit/3`, one post-commit hook

All three single-note content-write sites (the checkpoint, and the update and moved branches of `upsert_note`) duplicate the same "content changed: enqueue embed, enqueue link extraction" block. This task folds that into one function that also enqueues `FinalizeRevision`, so the next content side effect has one home. The batch path keeps its own bulk `insert_all` logic (priority promotion, no per-note SELECT) and gains one more `insert_all`.

**Files:**
- Create: `lib/engram/notes/content_commit.ex`
- Modify: `lib/engram/notes/crdt_checkpoint.ex` (the `if prev_hash != new_hash do` block, about line 258), `lib/engram/notes.ex` (`upsert_note/4`'s two `prev_hash != note.content_hash` blocks, about lines 464 and 527; `batch_upsert_side_effects/3`, about line 4103)
- Test: `test/engram/notes/content_commit_test.exs`

**Interfaces:**
- Consumes: `FinalizeRevision.new_for_note/2` (Task 3).
- Produces: `Engram.Notes.ContentCommit.after_commit(note_id :: String.t(), user_id :: String.t(), opts :: [embed_priority: integer()]) :: :ok`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/notes/content_commit_test.exs
defmodule Engram.Notes.ContentCommitTest do
  @moduledoc """
  Every content write must enqueue the same post-commit work. Before this
  module, the checkpoint and upsert_note each carried their own copy of that
  block, and a feature added to one could miss the other. That is exactly how
  #1710 would have shipped if it had hooked only the checkpoint: no history
  for any MCP edit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{ContentCommit, CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Commit", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp assert_all_enqueued(note_id) do
    for worker <- [EmbedNote, ExtractNoteLinks, FinalizeRevision] do
      assert_enqueued(worker: worker, args: %{note_id: note_id})
    end
  end

  test "after_commit enqueues embed, links and finalize" do
    note_id = Ecto.UUID.generate()
    :ok = ContentCommit.after_commit(note_id, Ecto.UUID.generate(), embed_priority: 0)
    assert_all_enqueued(note_id)
  end

  test "an upsert that changes content runs it", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "one"})
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "two"})
    assert_all_enqueued(note.id)
  end

  test "a content-changing checkpoint runs it", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "c.md", "content" => "before"})
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "after")

    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)

    assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
  end

  test "batch_upsert_notes enqueues finalize for changed notes", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "b.md", "content" => "one"})
    Notes.batch_upsert_notes(u, v, [%{"path" => "b.md", "content" => "two"}])
    assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram/notes/content_commit_test.exs`
Expected: compile error (`ContentCommit` undefined). After the next step, the three site tests fail on `FinalizeRevision` not being enqueued.

- [ ] **Step 3: Write `ContentCommit`**

```elixir
# lib/engram/notes/content_commit.ex
defmodule Engram.Notes.ContentCommit do
  @moduledoc """
  The post-commit work every committed note CONTENT change needs, in one place.

  Called by the single-note write sites (the CRDT checkpoint, and both
  content branches of `Notes.upsert_note/4`) after the write's transaction
  commits, only when the content hash actually changed. The batch path keeps
  its own bulk `Oban.insert_all` version for throughput.

  Site-specific work stays at the site: the checkpoint's announce, upsert's
  broadcast and link rebind.
  """
  alias Engram.Notes.Enqueue
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision}

  @spec after_commit(String.t(), String.t(), keyword()) :: :ok
  def after_commit(note_id, user_id, opts \\ []) when is_binary(note_id) and is_binary(user_id) do
    _ =
      Enqueue.enqueue(
        EmbedNote.new_debounced(note_id, user_id, priority: Keyword.get(opts, :embed_priority, 0)),
        "embed_note"
      )

    # #648 lever 1: cheap edge extraction must not ride the embed debounce
    # (30s) or the embed budget gate; ~2s leading edge.
    _ = Enqueue.enqueue(ExtractNoteLinks.new_debounced(note_id, user_id), "extract_note_links")

    # #1710: move any version copy this write's transaction left behind.
    _ = Enqueue.enqueue(FinalizeRevision.new_for_note(note_id, user_id), "finalize_revision")

    :ok
  end
end
```

- [ ] **Step 4: Route the three single-note sites through it**

In `lib/engram/notes/crdt_checkpoint.ex`, inside `if prev_hash != new_hash do`, replace the two `Enqueue.enqueue(...)` calls (EmbedNote and ExtractNoteLinks) and their comments with:

```elixir
                :ok = ContentCommit.after_commit(note_id, user_id, embed_priority: embed_priority)
```

Keep `CrdtDeliver.announce_ready(user_id, vault_id, path, note_id)` and its comment exactly as they are. Add `ContentCommit` to the module's `alias Engram.Notes.{...}` line, and drop `EmbedNote`/`ExtractNoteLinks` from the `alias Engram.Workers.{...}` line if nothing else in the module uses them (`EmbedNote.priority_for/1` is still used about line 247, so keep `EmbedNote`).

In `lib/engram/notes.ex`, `upsert_note/4`, both the `{prev_hash, note, _, _}` branch and the `{:moved, prev_hash, note, _, _}` branch: replace the body of `if prev_hash != note.content_hash do ... end` (the two enqueues) with:

```elixir
              :ok =
                ContentCommit.after_commit(note.id, user.id,
                  embed_priority: EmbedNote.priority_for(note)
                )
```

Add `ContentCommit` to `lib/engram/notes.ex`'s `alias Engram.Notes.{...}`.

In `batch_upsert_side_effects/3`, directly after the `extract_jobs` `insert_all` line, add:

```elixir
    # #1710 — same hash gate; finalize any version copy the write left behind.
    finalize_jobs =
      ok_entries
      |> Enum.filter(fn %{result: {:ok, info}} -> info.prev_hash != info.content_hash end)
      |> Enum.map(fn %{result: {:ok, info}} -> FinalizeRevision.new_for_note(info.id, user.id) end)

    _ = if finalize_jobs != [], do: Oban.insert_all(finalize_jobs)
```

Add `FinalizeRevision` to `lib/engram/notes.ex`'s `alias Engram.Workers.{...}`.

- [ ] **Step 5: Run the new tests and the suites that already pin these enqueues**

Run: `mise exec -- mix test test/engram/notes/content_commit_test.exs test/engram/notes/crdt_checkpoint_test.exs test/engram/notes/crdt_embed_coalescing_test.exs test/engram/notes_test.exs test/engram/links_test.exs`
Expected: PASS. This is a refactor plus one extra job, so no existing assertion should change.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/notes/content_commit.ex lib/engram/notes/crdt_checkpoint.ex lib/engram/notes.ex test/engram/notes/content_commit_test.exs
git commit -m "refactor(notes): one post-commit hook for content writes"
```

---

### Task 5: Record versions from the CRDT checkpoint

**Files:**
- Modify: `lib/engram/notes/crdt_checkpoint.ex`, `checkpoint_write/6`'s content branch, the `{1, _} ->` arm of `case Repo.update_all(fenced_query, set: set)` (about line 558)
- Test: `test/engram/notes/revisions_write_path_test.exs`

**Interfaces:**
- Consumes: `Revisions.record_write/4` (Task 2).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/notes/revisions_write_path_test.exs
defmodule Engram.Notes.RevisionsWritePathTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note, Revision, Revisions}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "WritePath", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  def revisions(user, note_id) do
    {:ok, revs} = Repo.with_tenant(user.id, fn -> Repo.all(from(r in Revision, where: r.note_id == ^note_id)) end)
    revs
  end

  def open(revs), do: Enum.find(revs, &is_nil(&1.closed_at))
  def text_of(user, rev), do: elem(Revisions.decrypt_pending(rev, user), 1)

  def checkpoint_text(user, vault, note_id, text) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note_id, doc)
  end

  describe "checkpoint" do
    test "a content change records a baseline and opens a sync version", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "cp.md", "content" => "before"})

      checkpoint_text(u, v, note.id, "after")

      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.origin == "baseline"))) == "before"
      assert %Revision{actor: "sync"} = open(revs)
    end

    test "a compaction (unchanged text) records nothing new", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "cp2.md", "content" => "before"})
      checkpoint_text(u, v, note.id, "after")
      count = length(revisions(u, note.id))

      checkpoint_text(u, v, note.id, "after")

      assert length(revisions(u, note.id)) == count
    end
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram/notes/revisions_write_path_test.exs`
Expected: FAIL on `revisions/2` returning `[]`.

- [ ] **Step 3: Hook the checkpoint**

In `checkpoint_write/6`, content branch, change the success arm:

```elixir
        case Repo.update_all(fenced_query, set: set) do
          {1, _} ->
            prune_tail(note_id, vault_id, prune)

            # #1710. AFTER the fenced write, in the same transaction: the {0, _}
            # arm below commits the transaction too, so a history step placed
            # before the write would record a version for a save that never
            # happened. `note` is the PRE-write row, so its content_ciphertext
            # is exactly the text this checkpoint replaced. Every edit that
            # reaches a checkpoint is the user's own CRDT clients: actor "sync".
            _ = Revisions.record_write(note, user, "sync")

            {prev, content_hash, note.path}
```

Add `Revisions` to the module's `alias Engram.Notes.{...}`. Leave the compaction branch (`prev == content_hash`) and the structural (`.canvas`) branch untouched: the first changes no text, and the second projects none (#1710 records markdown only).

- [ ] **Step 4: Run the tests and the checkpoint suites**

Run: `mise exec -- mix test test/engram/notes/revisions_write_path_test.exs test/engram/notes/crdt_checkpoint_test.exs test/engram/notes/crdt_checkpoint_backpressure_test.exs test/engram/notes/crdt_checkpoint_rotation_fence_test.exs test/engram/notes/checkpoint_interleave_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/crdt_checkpoint.ex test/engram/notes/revisions_write_path_test.exs
git commit -m "feat(history): record versions from the CRDT checkpoint"
```

---

### Task 6: Record versions from `upsert_note` (REST, MCP, batch) with an actor

**Files:**
- Modify: `lib/engram/notes.ex`: `do_update_note/7` (about line 1845), `do_rewrite_note/6` (about line 1970), `update_batch_entry/3` (about line 3976)
- Test: `test/engram/notes/revisions_write_path_test.exs` (add a `describe`), and create `test/engram/notes/revisions_interleave_test.exs`

**Interfaces:**
- Consumes: `Revisions.record_write/4`.
- Produces: `Notes.upsert_note(user, vault, attrs, actor: String.t())`. When `:actor` is absent it defaults to `"api"`.

- [ ] **Step 1: Write the failing tests**

Append to `test/engram/notes/revisions_write_path_test.exs`, inside the module:

```elixir
  describe "upsert_note" do
    test "an update records with the caller's actor", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "up.md", "content" => "v1"})

      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "up.md", "content" => "v2"}, actor: "mcp")

      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.origin == "baseline"))) == "v1"
      assert %Revision{actor: "mcp"} = open(revs)
    end

    test "no actor means \"api\"", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "api.md", "content" => "v1"})
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "api.md", "content" => "v2"})
      assert %Revision{actor: "api"} = open(revisions(u, note.id))
    end

    test "you typing, then an MCP write: your version holds exactly your text",
         %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "split.md", "content" => "start"})
      checkpoint_text(u, v, note.id, "you typed this")
      yours = open(revisions(u, note.id))

      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "split.md", "content" => "ai rewrote"}, actor: "mcp")

      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.id == yours.id))) == "you typed this"
      assert %Revision{actor: "mcp"} = open(revs)
    end

    test "an idempotent re-push records nothing", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "same.md", "content" => "v1"})
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "same.md", "content" => "v2"}, actor: "mcp")
      count = length(revisions(u, note.id))

      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "same.md", "content" => "v2"}, actor: "mcp")

      assert length(revisions(u, note.id)) == count
    end

    test "batch updates record as import", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "bulk.md", "content" => "v1"})
      Notes.batch_upsert_notes(u, v, [%{"path" => "bulk.md", "content" => "v2"}])
      assert %Revision{actor: "import", origin: "import"} = open(revisions(u, note.id))
    end
  end
```

Create the interleave test:

```elixir
# test/engram/notes/revisions_interleave_test.exs
defmodule Engram.Notes.RevisionsInterleaveTest do
  @moduledoc """
  Review focus #1 for #1710: a LOSING fenced write must record no history.

  The REST/MCP write parks after reading the row; a content-changing checkpoint
  commits in the gap; the write resumes, loses its snapshot fence, and retries
  INSIDE the same transaction (#1335). A history step placed before the fenced
  write would persist a version from the losing attempt, a duplicate baseline
  of stale text. The step must run only after a write that succeeded.

  Real connections (Engram.CheckpointInterleave): the sandbox serializes all
  work onto one connection, so nothing could commit into the gap.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note, Revision, Revisions}

  setup do
    CheckpointInterleave.checkout_real!()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user, id: user_id, email: "rev-interleave-#{System.unique_integer([:positive])}@test.com")

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "RevInterleave", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "a write that loses its fence and retries records one clean chain",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "BODY"})

    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, live} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(live, CrdtBridge.text_name()), "BODY LIVE")

    on_exit(CheckpointInterleave.arm(:after_note_read))

    writer =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "BODY REST"}, actor: "mcp")
      end)

    parked = CheckpointInterleave.await_parked(:after_note_read, writer.pid)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)
    CheckpointInterleave.release(:after_note_read, parked)
    assert {:ok, _} = Task.await(writer, 15_000)

    revs = Repo.all(from(r in Revision, where: r.note_id == ^note.id), skip_tenant_check: true)

    assert Enum.count(revs, &is_nil(&1.closed_at)) == 1
    assert Enum.count(revs, &(&1.origin == "baseline")) == 1,
           "the losing attempt left a second baseline: #{inspect(Enum.map(revs, & &1.origin))}"

    baseline = Enum.find(revs, &(&1.origin == "baseline"))
    sync = Enum.find(revs, &(&1.actor == "sync"))
    assert {:ok, "BODY"} = Revisions.decrypt_pending(baseline, user)
    assert {:ok, "BODY LIVE"} = Revisions.decrypt_pending(sync, user)
    assert %Revision{actor: "mcp", closed_at: nil} = Enum.find(revs, &is_nil(&1.closed_at))
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram/notes/revisions_write_path_test.exs test/engram/notes/revisions_interleave_test.exs`
Expected: the `upsert_note` tests FAIL (no rows recorded); the interleave test FAILs because no `mcp` open version exists.

- [ ] **Step 3: Thread the actor and hook the write**

In `do_update_note/7`, change the final `true ->` branch to pass the actor through:

```elixir
      true ->
        do_rewrite_note(existing, base_attrs, user, sanitized_path, folder,
          db_mode: Keyword.get(opts, :db_mode),
          actor: Keyword.get(opts, :actor, "api")
        )
```

In `do_rewrite_note/6`, change the success arm of `case fenced_update(...)`:

```elixir
          {:ok, updated} ->
            # #1710. AFTER the fenced write, in the same transaction:
            # `lookup_and_write` retries a lost fence INSIDE this transaction,
            # so a history step placed before the write would commit a version
            # for the losing attempt. `existing` is the PRE-write row. The
            # hash check keeps a write that rewrote no text out of history.
            _ =
              if existing.content_hash != crdt.content_hash,
                do: Revisions.record_write(existing, user, Keyword.get(opts, :actor, "api"))

            {:ok, {existing.content_hash, updated, crdt.merged_text, crdt.content_hash}}
```

In `update_batch_entry/3`, pass the batch actor:

```elixir
    case do_update_note(existing, base_attrs, user, entry.path, entry.folder, entry.tags,
           db_mode: :savepoint,
           actor: "import"
         ) do
```

Add `Revisions` to `lib/engram/notes.ex`'s `alias Engram.Notes.{...}`. `upsert_note/4` already forwards its `opts` (through `w.opts`) into `do_update_note/7`, so `actor:` reaches the hook with no further change.

- [ ] **Step 4: Run the tests and the write-path suites**

Run: `mise exec -- mix test test/engram/notes/revisions_write_path_test.exs test/engram/notes/revisions_interleave_test.exs test/engram/notes/rest_write_interleave_test.exs test/engram/notes_test.exs test/engram/notes_delete_tombstone_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes.ex test/engram/notes/revisions_write_path_test.exs test/engram/notes/revisions_interleave_test.exs
git commit -m "feat(history): record versions from upsert with the writer's actor"
```

---

### Task 7: Name the actor at every caller

**Files:**
- Create: `lib/engram_web/write_actor.ex`, `test/engram_web/write_actor_test.exs`, `test/engram/mcp/handlers_write_actor_test.exs`
- Modify: `lib/engram/mcp/handlers.ex` (6 `Notes.upsert_note` calls), `lib/engram_web/controllers/notes_controller.ex` (3 calls), `lib/engram/links/rewriter.ex` (1 call, about line 537), `lib/engram/notes/utf8_backfill.ex` (1 call, about line 155)

**Interfaces:**
- Consumes: `Notes.upsert_note/4`'s `actor:` opt (Task 6).
- Produces: `EngramWeb.WriteActor.for_conn(%Plug.Conn{}) :: String.t()`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram_web/write_actor_test.exs
defmodule EngramWeb.WriteActorTest do
  use ExUnit.Case, async: true

  alias EngramWeb.WriteActor

  test "an API key is its own actor" do
    conn = %Plug.Conn{assigns: %{current_api_key: %{id: "key-1"}}}
    assert WriteActor.for_conn(conn) == "api:key-1"
  end

  test "anything else is the user's own client" do
    assert WriteActor.for_conn(%Plug.Conn{assigns: %{}}) == "sync"
  end
end
```

```elixir
# test/engram/mcp/handlers_write_actor_test.exs
defmodule Engram.MCP.HandlersWriteActorTest do
  @moduledoc """
  Every MCP note write must record as actor "mcp", or an AI edit merges into
  the user's own version and "undo just the AI's change" stops working (#1710).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.MCP.Handlers
  alias Engram.{Notes, Repo}
  alias Engram.Notes.Revision

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "MCP Actor", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "write_note records as mcp", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "m.md", "content" => "mine"})

    Handlers.handle("write_note", u, v, %{"path" => "m.md", "content" => "the AI's"})

    {:ok, open} =
      Repo.with_tenant(u.id, fn ->
        Repo.one(from(r in Revision, where: r.note_id == ^note.id and is_nil(r.closed_at)))
      end)

    assert %Revision{actor: "mcp"} = open
  end

  # A new MCP write tool that forgets the actor would silently default to
  # "api". Every upsert call in the handlers module must carry @write_opts.
  test "every upsert_note call in Handlers passes the mcp actor" do
    source = File.read!("lib/engram/mcp/handlers.ex")
    calls = length(Regex.scan(~r/Notes\.upsert_note\(/, source))
    with_actor = length(Regex.scan(~r/@write_opts\s*\)/, source))

    assert calls > 0
    assert calls == with_actor
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram_web/write_actor_test.exs test/engram/mcp/handlers_write_actor_test.exs`
Expected: compile error (`WriteActor` undefined); the MCP tests fail (actor `"api"`; 0 calls carry `@write_opts`).

- [ ] **Step 3: Write `WriteActor` and wire every caller**

```elixir
# lib/engram_web/write_actor.ex
defmodule EngramWeb.WriteActor do
  @moduledoc """
  The history actor for a REST note write (#1710).

  An API key is its own actor, so a script's edits form versions separate from
  yours. Every other authenticated REST client (the web app, the plugin's
  device-flow token) is the user's own client, the same actor as their CRDT
  edits. MCP does not come through here; `Engram.MCP.Handlers` passes "mcp".
  """
  @spec for_conn(Plug.Conn.t()) :: String.t()
  def for_conn(%Plug.Conn{assigns: %{current_api_key: %{id: id}}}), do: "api:#{id}"
  def for_conn(%Plug.Conn{}), do: "sync"
end
```

In `lib/engram/mcp/handlers.ex`, add near the top of the module:

```elixir
  # #1710: every MCP note write is the "mcp" history actor. The
  # HandlersWriteActorTest counts that every upsert_note call passes this.
  @write_opts [actor: "mcp"]
```

Then give each of the six `Notes.upsert_note(user, vault, %{...})` calls a fourth argument, `@write_opts`, so each call ends `}, @write_opts)`. Find them with `grep -n 'Notes.upsert_note' lib/engram/mcp/handlers.ex`.

In `lib/engram_web/controllers/notes_controller.ex`, give each of the three `Notes.upsert_note` calls the opt `actor: EngramWeb.WriteActor.for_conn(conn)` (for the 3-arity calls, add it as the fourth argument).

In `lib/engram/links/rewriter.ex`:

```elixir
               Notes.upsert_note(user, vault, %{"path" => path, "content" => new_text},
                 actor: "link_rewrite"
               ) do
```

In `lib/engram/notes/utf8_backfill.ex`, change `force: true` to `force: true, actor: "maintenance"`.

- [ ] **Step 4: Run the tests and the caller suites**

Run: `mise exec -- mix test test/engram_web/write_actor_test.exs test/engram/mcp/ test/engram_web/controllers/notes_controller_test.exs test/engram/links/`
Expected: PASS. If `notes_controller_test.exs` has a different name, run `test/engram_web/controllers/`.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/write_actor.ex lib/engram/mcp/handlers.ex lib/engram_web/controllers/notes_controller.ex lib/engram/links/rewriter.ex lib/engram/notes/utf8_backfill.ex test/engram_web/write_actor_test.exs test/engram/mcp/handlers_write_actor_test.exs
git commit -m "feat(history): name the writer at every note-write caller"
```

---

### Task 8: The hourly sweep for stranded copies

`after_commit` enqueues finalize right after the transaction commits. A process that dies in between leaves a copy with no job. This sweep catches it.

**Files:**
- Create: `lib/engram/workers/finalize_revision_sweep.ex`, `test/engram/workers/finalize_revision_sweep_test.exs`
- Modify: `config/config.exs` (crontab), `test/engram/oban_cron_test.exs`

**Interfaces:**
- Consumes: `FinalizeRevision.new_for_note/2`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/workers/finalize_revision_sweep_test.exs
defmodule Engram.Workers.FinalizeRevisionSweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{Note, Revision, Revisions}
  alias Engram.Workers.{FinalizeRevision, FinalizeRevisionSweep}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Sweep", Ecto.UUID.generate())
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s.md", "content" => "stranded"})
    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, :ok} = Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, user, "sync") end)
    %{user: user, note: note}
  end

  defp age_pending(user, note_id, seconds) do
    then = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(r in Revision, where: r.note_id == ^note_id and not is_nil(r.pending_ciphertext)),
          set: [updated_at: then]
        )
      end)
  end

  test "re-enqueues a copy stranded for over ten minutes", %{user: u, note: n} do
    age_pending(u, n.id, 3600)
    assert :ok = perform_job(FinalizeRevisionSweep, %{})
    assert_enqueued(worker: FinalizeRevision, args: %{note_id: n.id})
  end

  test "leaves a fresh copy to its own job", %{note: n} do
    assert :ok = perform_job(FinalizeRevisionSweep, %{})
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: n.id})
  end
end
```

In `test/engram/oban_cron_test.exs`, change the third test to cover both sweeps:

```elixir
  for worker <- [Engram.Workers.CrdtBloatSweep, Engram.Workers.FinalizeRevisionSweep] do
    @worker worker
    test "#{inspect(worker)} does not collide with any other entry" do
      entry = Enum.find(crontab(), fn {_, w} -> w == @worker end)

      assert entry,
             "#{inspect(@worker)} is not scheduled — this test guards its slot, so removing " <>
               "the entry should be a deliberate edit here too"

      {expr, _} = entry
      mine = slots(expr)

      others =
        crontab()
        |> Enum.reject(fn {_, w} -> w == @worker end)
        |> Enum.flat_map(fn {e, w} -> for slot <- slots(e), MapSet.member?(mine, slot), do: {slot, w} end)

      assert others == [], "#{inspect(@worker)} (#{expr}) shares its minute with: #{inspect(others)}"
    end
  end
```

(Delete the old single-worker `"the CRDT bloat sweep does not collide with any other entry"` test this replaces.)

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/engram/workers/finalize_revision_sweep_test.exs test/engram/oban_cron_test.exs`
Expected: compile error (`FinalizeRevisionSweep` undefined); the cron test fails on "not scheduled".

- [ ] **Step 3: Write the sweep and schedule it**

```elixir
# lib/engram/workers/finalize_revision_sweep.ex
defmodule Engram.Workers.FinalizeRevisionSweep do
  @moduledoc """
  Hourly backstop for note-version outbox copies left without a job (#1710).

  `ContentCommit.after_commit/3` enqueues `FinalizeRevision` after the write's
  transaction commits. A process that dies in between leaves the copy in
  `note_revisions.pending_*` with nothing coming for it. This finds copies older
  than ten minutes (well past any live job's 5s schedule plus retries) and
  enqueues them again. Re-enqueueing is safe: `FinalizeRevision` takes a lock
  and re-reads, so a duplicate finds nothing to do.

  Refuses rather than sweeping blind where RLS is enforced and no maintenance
  pool is configured, the same guard as `Engram.Workers.OrphanSweep`: the read
  would return zero rows, which looks identical to "nothing stranded".
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Engram.Logger.Metadata
  alias Engram.Notes.Revision
  alias Engram.Repo
  alias Engram.Workers.FinalizeRevision

  require Logger

  @stale_after_seconds 600
  @batch 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if tenancy_unsafe?() do
      Logger.error(
        "finalize_revision_sweep refusing to run: RLS enforcement could not be ruled out " <>
          "and no maintenance pool is configured, so the read would return zero rows",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      sweep()
    end
  end

  defp sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    pairs =
      Repo.maintenance().all(
        from(r in Revision,
          where: not is_nil(r.pending_ciphertext) and r.updated_at < ^cutoff,
          distinct: true,
          select: {r.note_id, r.user_id},
          limit: @batch
        ),
        skip_tenant_check: true
      )

    jobs = Enum.map(pairs, fn {note_id, user_id} -> FinalizeRevision.new_for_note(note_id, user_id) end)
    _ = if jobs != [], do: Oban.insert_all(jobs)
    :ok
  end

  defp tenancy_unsafe? do
    Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?()
  end
end
```

In `config/config.exs`'s crontab, after the `CrdtBloatSweep` entry (add a comma to it):

```elixir
       # Backstop for note-version outbox copies whose FinalizeRevision job was
       # lost between commit and enqueue (#1710). :35 past every hour: clear of
       # :00 (CleanupDeviceAuthWorker), the quarter-hours (ReconcileEmbeddings),
       # :10 (CrdtBloatSweep), and every daily slot above. ObanCronTest pins it.
       {"35 * * * *", Engram.Workers.FinalizeRevisionSweep}
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- mix test test/engram/workers/finalize_revision_sweep_test.exs test/engram/oban_cron_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/workers/finalize_revision_sweep.ex config/config.exs test/engram/workers/finalize_revision_sweep_test.exs test/engram/oban_cron_test.exs
git commit -m "feat(history): sweep stranded version copies hourly"
```

---

### Task 9: Docs and the full gate

**Files:**
- Create: `docs/context/note-revisions-history.md`
- Modify: `AGENTS.md` (Context Docs index)

- [ ] **Step 1: Write the context doc**

```markdown
# Note revisions: how version history is recorded (#1710)

**Trigger:** working on note history, restore (#1711), retention (#1712), DEK
rotation of history (#1713), or any code that writes `notes.content`.

## The model

- A version is one editing session by one actor. It closes when a different
  actor writes, after 10 idle minutes (`HISTORY_SESSION_GAP_MINUTES`), or on
  the note's first save after history shipped (that save keeps a `baseline`).
- Actors: `sync` (your editor, plugin and CRDT clients, all one actor), `mcp`,
  `api:<key_id>`, `import`, `link_rewrite`, `maintenance`.
- The open version (`closed_at IS NULL`) has no stored text: it IS the note.

## The outbox

`Engram.Notes.Revisions.record_write/4` runs INSIDE each content write's
transaction, right after the fenced UPDATE succeeds. On a boundary it copies the
note's OLD `content_ciphertext` into the closing version's `pending_*` columns,
with no decrypt and no storage I/O. `Engram.Workers.FinalizeRevision` later
decrypts it (notes AAD), gzips it, re-encrypts it (revision AAD), stores it at
`revisions/<user>/<vault>/<note>/<rev>`, and clears the copy.

## Traps

- **Hook AFTER the fenced write, never before.** A losing fenced write does not
  abort its transaction (the checkpoint's `{0, _}` commits; `lookup_and_write`
  retries in-transaction), so a pre-write hook records saves that never
  happened. `revisions_interleave_test.exs` pins this.
- **A new content-write path must call `Revisions.record_write/4` and
  `ContentCommit.after_commit/3`.** Two sites today: `CrdtCheckpoint.checkpoint_write/6`
  and `Notes.do_rewrite_note/6`. Missing one means no history for that writer.
- **New MCP write tools pass `@write_opts`**, or AI edits merge into your
  version. `HandlersWriteActorTest` counts the calls.
- **Never store Yjs snapshots as versions.** Yjs snapshot restore needs
  `gc: false`, which would make `crdt_state` grow without bound.
- **Prod is OFF** (`HISTORY_RECORDING`) until #1713 (rotation rewraps
  `pending_*` and blobs) and #1715 (the orphan sweep walks `revisions/`) ship.
- **The finalize lock matters.** Two concurrent finalizes without
  `Repo.advisory_lock!/1` each PUT with their own nonce, and only one nonce
  reaches the row.
```

In `AGENTS.md`'s Context Docs index, add next to the other notes/CRDT entries:

```markdown
- Note version history, the outbox write path, adding a content-write path or an MCP write tool → `docs/context/note-revisions-history.md`
```

- [ ] **Step 2: Run the full gate**

Run each, in order, and fix anything red before moving on:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix credo --strict
mise exec -- mix dialyzer
mise exec -- mix test
```

Expected: format clean, credo `found no issues`, dialyzer at the main baseline (`Total errors: 5, Skipped: 5`), full suite 0 failures. If the full `mix test` gets OOM-killed in the background, run it in foreground chunks: `test/engram_web test/integration test/lint test/mix`, then the first and second halves of `test/engram/*/`, then `test/engram/*_test.exs`.

- [ ] **Step 3: Commit**

```bash
git add docs/context/note-revisions-history.md AGENTS.md
git commit -m "docs(context): record how note history is written"
```

---

## Self-review against the spec

- **Versions = session by actor; gap; first-save baseline:** Task 2.
- **Actors and naming at callers:** Tasks 5 (sync), 6 (default api, import), 7 (mcp, api key, link_rewrite, maintenance).
- **Transactional outbox, after the fenced write:** Tasks 2, 5, 6; race pinned by the Task 6 interleave test.
- **Open version has no copy:** Task 2 (never copies on open), Task 1 (`closed_at IS NULL`).
- **FinalizeRevision, idempotent, AAD-bound, both adapters:** Task 3. The bytea adapter shares the `Engram.Storage` behaviour; tests run on `InMemory`.
- **Projected text, never Yjs state:** Tasks 5/6 copy `content_ciphertext` only.
- **Limit key through Billing:** Task 2 (`history_enabled` via `Billing.granted?/2`). The two retention keys are deferred to #1712 (v2.1 #4).
- **Data model, one-open index, pending index, RLS + maintenance + tenant_tables:** Task 1.
- **Storage key, top-level prefix:** Task 3.
- **ContentCommit consolidation:** Task 4.
- **Kill switch, prod off:** Task 2 config.
- **Pending sweep:** Task 8.
- **Out of scope, untouched:** read API/restore, prune, rotation, lifecycle rule, orphan sweep, UI.
