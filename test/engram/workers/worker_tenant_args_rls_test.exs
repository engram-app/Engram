defmodule Engram.Workers.WorkerTenantArgsRlsTest do
  @moduledoc """
  Pins the worker note/vault fetches against an ENFORCED row-level security
  policy, and pins `user_id` into the job args that make that scoping possible.

  ## What this is about

  Observed on staging the moment the app pool dropped from the migrator role to
  `engram_app`: creating ONE note produced three discards —

    * `ExtractNoteLinks` -> `{:discard, "note ... not found"}`
    * `EmbedNote`        -> `{:discard, "note ... not found"}`
    * `RebindNoteLinks`  -> `{:discard, "vault ... not found"}`

  for a note and a vault that plainly existed. The client saw a successful
  write; the note got 0 chunks, 0 links, and a NULL `embed_hash`. Nothing
  raised, nothing alerted — the reads were simply FILTERED to zero rows.

  Neither worker can discover its own tenant: the note is the very row RLS is
  hiding, so there is nothing to read a `user_id` off of. That is why `user_id`
  travels in the job args instead — the enqueuer always knows it, because it
  just wrote the note. These tests fence both halves: the args carrying it, and
  the fetch actually using it.

  ## Why the rest of the suite does not catch this

  `extract_note_links_test.exs` and friends cover these workers' behaviour and
  pass — as the SUPERUSER the test database connects as, which bypasses RLS
  even when it is FORCED. Correct behaviour there says nothing about
  enforcement. This file drops to `engram_app` (no SUPERUSER, no BYPASSRLS) so
  the policy actually applies.

  See `docs/context/rls-enforcement-testing-traps.md` for the traps this
  harness is shaped around — in particular the tenant-leak trap that makes the
  CONTROL test below load-bearing. `async: false` because the role change is
  connection-global.
  """

  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Links
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.ExtractNoteLinks
  alias Engram.Workers.RebindNoteLinks
  alias Engram.Workers.RepathNoteIndex

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, target} =
      Notes.upsert_note(user, vault, %{"path" => "Target.md", "content" => "# t"})

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Source.md", "content" => "see [[Target]]"})

    # Derived OUTSIDE the prod-role scope deliberately. Key derivation reads the
    # user row and warms the DEK cache; doing it inside the dropped role would
    # test the cache's state rather than the code under test.
    basename_hmac = Links.basename_hmac(user, "target")

    {:ok, user: user, vault: vault, note: note, target: target, basename_hmac: basename_hmac}
  end

  describe "Notes.fetch_note_for_worker under enforced RLS" do
    # CONTROL. Without this a green file is ambiguous between "correctly
    # scoped" and "the role drop never engaged".
    test "control: the dropped role cannot see the seeded note", %{note: note} do
      outcome =
        as_prod_role(fn ->
          Repo.one(
            from(n in Note, where: n.id == ^note.id, select: count(n.id)),
            skip_tenant_check: true
          )
        end)

      assert outcome == {:returned, 0},
             """
             Harness is not engaging RLS, so every assertion in this file is meaningless.

               rows visible as engram_app with no tenant: #{inspect(outcome)} (expected {:returned, 0})

             Either SET LOCAL ROLE did not apply, or the tenant was not cleared
             (see the tenant-leak trap in rls-enforcement-testing-traps.md), or
             the role has BYPASSRLS.
             """
    end

    test "/2 finds the note using the tenant from the job args", %{note: note, user: user} do
      assert {:returned, {:ok, %Note{} = found}} =
               as_prod_role(fn -> Notes.fetch_note_for_worker(note.id, user.id) end),
             "the scoped fetch could not see its own note — every worker keyed on it discards"

      assert found.id == note.id
    end

    test "/1 (legacy bridge) is filtered to nothing — this is the staging bug", %{note: note} do
      # Pins the REASON /2 exists. The legacy arity is correct only while the
      # app connects as a migrator-grade role; under `engram_app` it returns
      # nil and the caller discards a note that exists. Kept only to drain jobs
      # enqueued before `user_id` was in the args.
      assert {:returned, {:discard, reason}} =
               as_prod_role(fn -> Notes.fetch_note_for_worker(note.id) end)

      assert reason =~ "not found"
    end

    test "job helper scopes when args carry user_id, and does not when they do not",
         %{note: note, user: user} do
      assert {:returned, {:ok, %Note{}}} =
               as_prod_role(fn ->
                 Notes.fetch_note_for_worker_job(%{
                   "note_id" => note.id,
                   "user_id" => user.id
                 })
               end)

      assert {:returned, {:discard, _}} =
               as_prod_role(fn ->
                 Notes.fetch_note_for_worker_job(%{"note_id" => note.id})
               end)
    end
  end

  describe "worker perform/1 under enforced RLS" do
    # CONTROL for the two vault reads below. `vaults` also carries FORCE ROW
    # LEVEL SECURITY, and this is the exact shape both workers used before:
    # `Repo.get(Vault, id, skip_tenant_check: true)`. It answers nil for a
    # vault that exists, which both workers then reported as
    # {:discard, "vault ... not found"}.
    #
    # Without this the two perform/1 tests are ambiguous — they would pass
    # whether the vault read is scoped or whether `vaults` simply is not
    # RLS-enforced at all.
    test "control: an unscoped vault read is filtered to nil", %{vault: vault} do
      assert {:returned, nil} =
               as_prod_role(fn -> Repo.get(Vault, vault.id, skip_tenant_check: true) end),
             "unscoped vault read was NOT filtered — the vault-scoping tests below prove nothing"
    end

    # CONTROL for the WRITE half. An UPDATE is FILTERED by the policy's USING
    # clause rather than rejected: {0, nil}, no error, nothing raised. That is
    # the shape behind EmbedNote's two unscoped writes — the poison-park and
    # the embed_hash stamp. Unscoped they stamp nothing, so the note re-embeds
    # on every sweep and re-pays Voyage, while the 0-row result is logged as a
    # benign "concurrent edit".
    test "control: an unscoped note UPDATE is filtered to zero rows", %{note: note} do
      assert {:returned, {0, _}} =
               as_prod_role(fn ->
                 from(n in Note, where: n.id == ^note.id)
                 |> Repo.update_all([set: [embed_retry_after: nil]], skip_tenant_check: true)
               end),
             "unscoped UPDATE was not filtered — the silent-write class is not reproduced"
    end

    test "ExtractNoteLinks reaches its work instead of discarding", %{note: note, user: user} do
      # Covers the NOTE FETCH only, and deliberately claims no more.
      #
      # It cannot cover the `Repo.get(Vault, ...)` inside extract/1: the fetch's
      # `with_tenant` exit runs `set_config('role', 'none', true)`, which under
      # the sandbox leaks FORWARD and reverts the role to the superuser default
      # for everything after it. So every statement in extract/1 beyond the
      # first scope runs unenforced, and reverting the vault read leaves this
      # test green. That is the Trap 2 corollary in
      # docs/context/rls-enforcement-testing-traps.md.
      #
      # The vault-read fix is pinned by the CONTROL above instead. The
      # `repair_rename_danglers` read is doubly uncovered: setup creates
      # Target.md before Source.md, so the edge binds and there are zero
      # danglers to find either way.
      assert {:returned, :ok} =
               as_prod_role(fn ->
                 ExtractNoteLinks.perform(%Oban.Job{
                   args: %{"note_id" => note.id, "user_id" => user.id},
                   attempt: 1,
                   max_attempts: 3
                 })
               end),
             "ExtractNoteLinks discarded or errored under enforced RLS"
    end

    test "RebindNoteLinks finds its vault", %{user: user, vault: vault, basename_hmac: hmac} do
      assert {:returned, :ok} =
               as_prod_role(fn ->
                 RebindNoteLinks.perform(%Oban.Job{
                   args: %{
                     "user_id" => user.id,
                     "vault_id" => vault.id,
                     "basename_hmac" => Base.encode64(hmac)
                   },
                   attempt: 1,
                   max_attempts: 3
                 })
               end),
             "RebindNoteLinks discarded with \"vault not found\" for a vault that exists"
    end

    test "EmbedNote reaches its already-indexed early return instead of discarding",
         %{note: note, user: user} do
      # Force the "already indexed by the current chunker" shape so perform/1
      # returns at its FIRST branch — no Voyage call, no Qdrant call, no
      # network. That makes this a pure test of the note fetch: if the read is
      # filtered by RLS, the result is {:discard, "note ... not found"} rather
      # than :ok, which is exactly what staging showed.
      {1, _} =
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(
          [
            set: [
              embed_hash: note.content_hash,
              dense_indexed_hash: note.content_hash,
              chunker_version: Engram.Parsers.Markdown.chunker_version()
            ]
          ],
          skip_tenant_check: true
        )

      assert {:returned, :ok} =
               as_prod_role(fn ->
                 EmbedNote.perform(%Oban.Job{
                   args: %{"note_id" => note.id, "user_id" => user.id},
                   attempt: 1,
                   max_attempts: 5
                 })
               end),
             "EmbedNote discarded under enforced RLS for a note that exists"
    end
  end

  describe "job args carry the tenant" do
    # These are the enqueue-side half. Without `user_id` in the args the scoped
    # fetch above has nothing to scope ON, so a regression here reintroduces
    # the staging bug without touching any of the code above.
    test "EmbedNote.new_debounced/3", %{note: note, user: user} do
      assert tenant_arg(EmbedNote.new_debounced(note.id, user.id)) == user.id
    end

    test "ExtractNoteLinks.new_debounced/2", %{note: note, user: user} do
      assert tenant_arg(ExtractNoteLinks.new_debounced(note.id, user.id)) == user.id
    end

    test "RepathNoteIndex.new_debounced/3", %{note: note, user: user} do
      assert tenant_arg(RepathNoteIndex.new_debounced(note.id, user.id, old_path_hmac: "abc")) ==
               user.id
    end
  end

  # Reads `user_id` out of a not-yet-inserted job changeset.
  #
  # Key type is normalized deliberately: the enqueue sites build args with ATOM
  # keys and Oban only stringifies them on insert, so a raw
  # `get_field(:args)["user_id"]` reads nil here and the assertion passes
  # vacuously in the other direction. Normalizing means this helper holds
  # whichever form the args happen to be in.
  defp tenant_arg(changeset) do
    changeset
    |> Ecto.Changeset.get_field(:args)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.get("user_id")
  end
end
