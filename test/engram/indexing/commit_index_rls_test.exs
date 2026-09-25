defmodule Engram.Indexing.CommitIndexRlsTest do
  @moduledoc """
  Pins `Indexing.commit_index/1` against an ENFORCED row-level security policy.

  ## What this is about

  `commit_index/1` writes the `chunks` rows with

      Repo.delete_all(..., skip_tenant_check: true)
      Repo.insert_all(Chunk, chunk_rows, skip_tenant_check: true)

  and sets no tenant. `skip_tenant_check: true` suppresses only Engram's
  application-level guard in `Repo.prepare_query/3`; it sets nothing in
  Postgres. `chunks` carries FORCE ROW LEVEL SECURITY with

      WITH CHECK ((user_id)::text = current_setting('app.current_tenant', true))

  so with no tenant the check compares against NULL and Postgres rejects the
  insert outright:

      ERROR 42501 new row violates row-level security policy for table "chunks"

  The function's own docstring states the assumption plainly — "non-tenant-scoped
  callers (e.g. `EmbedNote`) run as the superuser role and bypass RLS". That is
  the invariant this test exists to remove. It holds today only because every
  environment connects as a superuser; it is not a property of the code.

  ## Why the existing suite does not catch it

  `indexing_test.exs` already asserts that `index_note/2` writes chunk rows and
  would fail on exactly this. It passes because the test and CI databases
  connect as `engram`, the cluster bootstrap SUPERUSER, and superusers bypass
  RLS even when it is FORCED. The rows are writable in test and rejected under
  any non-superuser role.

  ## Two traps this file is shaped around

  Both were hit for real while writing it, and either one silently voids every
  assertion below.

  **1. `Notes.upsert_note/3` leaves a tenant set.** It writes through
  `Repo.with_tenant/2`, which sets `app.current_tenant` with `set_config(..., true)`
  (SET LOCAL) and whose exit path resets only the ROLE, never the tenant. Under
  the Ecto sandbox the whole test runs inside ONE outer transaction, so that
  tenant persists into everything that follows. Without the explicit clear in
  `as_prod_role/1` the control below sees the note and the file passes while
  never exercising RLS at all.

  **2. Driving this through `index_note/2` would pass vacuously.** That path
  calls `IndexCap.within_cap?/2` first, which opens its own
  `Repo.with_tenant/2`. Its exit runs `set_config('role', 'none', true)`, and a
  subtransaction's `SET LOCAL` persists to the enclosing transaction once it
  commits — that is precisely why `Repo.with_tenant/2` resets the role from
  inside its own transaction. So the `engram_app` role would revert to the
  superuser default before `commit_index/1` ever ran.

  The test therefore splits the pipeline the way the docstring describes:
  `prepare_index/3` runs as the superuser (it performs no DB writes and makes
  the embedder call), and only `commit_index/1` runs under the dropped role.

  `async: false` because the role change is connection-global.
  """

  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  # The rolling-back variant: `commit_index/1` INSERTs, and INSERT is the one
  # statement the policy rejects rather than filters. Two tests below match on
  # `{:raised, error}` to turn that 42501 into a legible `flunk`, which is what
  # the tagged return is for.
  import Engram.RlsCase

  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Rls/CommitIndex.md",
        # The wikilink is required, not decorative: `replace_links/4` calls
        # `insert_all` with the extracted rows, and `insert_all(_, [])` is a
        # no-op that can never violate a policy. Without a link the
        # `replace_links/4` test below would pass vacuously.
        "content" =>
          "# Commit Index\n\nBody text that yields at least one chunk.\n\nSee [[Other Note]].",
        "mtime" => 1_000.0
      })

    # Reload. `insert(:user)` has no `encrypted_dek`; the first write through
    # `Notes.upsert_note/3` creates one. Passing the stale pre-DEK struct into
    # `prepare_index/3` makes it fail `{:error, :no_dek}` before it ever builds
    # chunk rows — a setup failure that looks nothing like the RLS behaviour
    # this file is about.
    user = Repo.get!(Engram.Accounts.User, user.id)

    {:ok, bypass: bypass, user: user, vault: vault, note: note}
  end

  # Catch-all. `Bypass.expect/2` requires at least one matching request, so it
  # belongs in the tests that actually talk to Qdrant — putting it in `setup`
  # fails the control test below, which performs no HTTP at all.
  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)
  end

  defp prepare!(note, vault, user) do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts -> {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)} end)

    {:ok, prepared} = Indexing.prepare_index(note, vault, user)

    # Guard against a vacuous run. `prepare_index/3` returns
    # `{:ok, {:no_chunks, link_rows}}` for an empty or over-cap note, and
    # `commit_index/1` is never reached on that branch — so without this the
    # test could "pass" having committed nothing.
    assert %{chunk_rows: [_ | _]} = prepared

    prepared
  end

  describe "commit_index/1 under enforced RLS" do
    # CONTROL. Without this, a green result below is ambiguous between "the
    # write is correctly tenant-scoped" and "the role drop never took effect,
    # so RLS was never in play". Asserts the harness actually bites.
    test "control: the dropped role cannot see the seeded note", %{note: note} do
      outcome =
        as_prod_role(fn ->
          Repo.one(from(n in Note, select: count(n.id)), skip_tenant_check: true)
        end)

      assert outcome == {:returned, 0},
             """
             Harness is not engaging RLS, so every other assertion in this file is meaningless.

               notes visible as engram_app with no tenant: #{inspect(outcome)} (expected {:returned, 0})
               note that exists:                           #{note.id}

             Either SET LOCAL ROLE did not apply, or the tenant was not cleared
             (see trap 1 in the moduledoc), or the role has BYPASSRLS.
             """
    end

    test "persists the chunk rows instead of being rejected by the policy",
         %{bypass: bypass, note: note, vault: vault, user: user} do
      stub_qdrant(bypass)
      prepared = prepare!(note, vault, user)

      case as_prod_role(fn -> Indexing.commit_index(prepared) end) do
        {:returned, {:ok, count}} ->
          assert count > 0, "commit_index reported success but committed no chunks"

        {:returned, other} ->
          flunk("commit_index/1 returned an unexpected value: #{inspect(other)}")

        {:raised, error} ->
          flunk("""
          commit_index/1 was rejected by row-level security.

            #{Exception.message(error)}

          The chunk write uses `skip_tenant_check: true`, which suppresses only
          Engram's own prepare_query guard — it sets no tenant in Postgres. Under
          any role without SUPERUSER or BYPASSRLS the WITH CHECK policy on
          `chunks` rejects the insert.

          This passes today only because every environment connects as a
          superuser. Scope the write with `Repo.with_tenant/2`.
          """)
      end
    end

    # The test above is NECESSARY BUT NOT SUFFICIENT, and this is the reason.
    #
    # `Repo.with_tenant/2` sets the tenant with `set_config(..., true)` — SET
    # LOCAL. Under the Ecto sandbox its transaction is a SAVEPOINT nested in
    # this test's outer transaction, and a subtransaction's SET LOCAL PERSISTS
    # to the enclosing transaction once it commits. So every statement
    # `commit_index/1` runs AFTER its own tenant block inherits that tenant for
    # free — including `Links.replace_links/4`.
    #
    # Production has no enclosing transaction. There `with_tenant/2` opens a
    # real top-level transaction and SET LOCAL is discarded at its commit, so
    # the following statements run with NO tenant.
    #
    # Net effect: scoping one write inside `commit_index/1` makes the test
    # above green while the later writes remain unscoped in prod. Each write on
    # the path therefore needs its own direct test, which is what this one is.
    test "replace_links/4 refuses to write note_links without a tenant of its own",
         %{bypass: bypass, note: note, vault: vault, user: user} do
      stub_qdrant(bypass)
      prepared = prepare!(note, vault, user)

      assert [_ | _] = prepared.links,
             "fixture produced no link rows, so insert_all would be a no-op and prove nothing"

      case as_prod_role(fn ->
             Engram.Links.replace_links(user, vault, note.id, prepared.links)
           end) do
        {:returned, :ok} ->
          :ok

        {:returned, other} ->
          flunk("replace_links/4 returned an unexpected value: #{inspect(other)}")

        {:raised, error} ->
          flunk("""
          replace_links/4 was rejected by row-level security.

            #{Exception.message(error)}

          `note_links` carries FORCE ROW LEVEL SECURITY. `links.ex` sets no
          tenant, and `commit_index/1` calls this AFTER its own tenant block
          has committed — so in prod it runs unscoped. Scope the write in
          `replace_links/4` itself rather than relying on a caller's tenant.
          """)
      end
    end

    # The test above STOPPED DISCRIMINATING at 63e74adb, and this one exists
    # because of it.
    #
    # That commit scoped `prefetch_candidates/4`, which is the FIRST statement
    # in `replace_links/4`. Under the sandbox its `with_tenant` is a savepoint
    # whose `SET LOCAL` persists to the enclosing transaction, so every later
    # statement — including the `insert_all` — inherits a tenant even when the
    # write block sets none of its own. Measured, not assumed: replacing the
    # `with_tenant` at `links.ex:141` with a bare `Repo.transaction` leaves the
    # test above GREEN at 63e74adb and RED at 0a4161fe.
    #
    # An empty parsed list cannot be masked that way. It short-circuits on
    # `prefetch_candidates(_user, _vault, [], _dek)` before anything is opened,
    # so no tenant leaks in and the DELETE must do its own scoping. DELETE is
    # FILTERED rather than rejected, so unscoped it reports `{0, nil}`, returns
    # `:ok`, and the old edges survive — which is exactly what this asserts.
    test "replace_links/4 scopes its DELETE without help from the prefetch",
         %{bypass: bypass, note: note, vault: vault, user: user} do
      stub_qdrant(bypass)
      prepared = prepare!(note, vault, user)

      edge_count = fn ->
        Repo.aggregate(
          from(l in "note_links", where: l.source_note_id == type(^note.id, Ecto.UUID)),
          :count,
          :id,
          skip_tenant_check: true
        )
      end

      # Seed as the superuser, so the delete below has something to remove.
      :ok = Engram.Links.replace_links(user, vault, note.id, prepared.links)

      assert edge_count.() > 0,
             "fixture seeded no edges, so the delete below would be a no-op and prove nothing"

      # Committing harness, deliberately: the assertion is about the rows being
      # GONE afterwards, and the rolling-back helper would discard the delete.
      :ok =
        as_prod_role_committing(fn ->
          Engram.Links.replace_links(user, vault, note.id, [])
        end)

      assert edge_count.() == 0,
             """
             replace_links/4 left the previous edges in place.

             The DELETE was FILTERED by row-level security rather than rejected,
             so it reported 0 rows affected and the call still returned :ok. That
             means the write block is relying on a tenant it did not set itself —
             which works under the sandbox and fails in prod.
             """
    end
  end
end
