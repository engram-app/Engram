defmodule Engram.Workers.ReconcileEmbeddingsMaintenanceTest do
  @moduledoc """
  Proves `ReconcileEmbeddings` sweeps every tenant in ONE pass on the
  maintenance pool when one is configured, instead of one transaction per
  user (O(users) per tick).

  The app pool is dropped to `engram_app` with no tenant, where the notes
  policy hides every row, while a real maintenance pool runs on its own
  connection. Only a sweep that reads through that pool finds the notes. The
  rows are COMMITTED so the second connection sees them, and deleted on exit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings, RefreshKeywordVectors}

  # Tags the committed users so a run that died before its on_exit can be
  # cleaned up by the next one.
  @email_prefix "reconcile-maintenance-test-"

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    delete_committed!()
    on_exit(&delete_committed!/0)

    # One note per tenant: one content-stale (embed sweep), one indexed at its
    # content with a stale keyword version (keyword sweep).
    Sandbox.unboxed_run(Repo, fn ->
      [stale, keyword] =
        for i <- 1..2 do
          email = "#{@email_prefix}#{i}-#{System.unique_integer([:positive])}@t.co"
          user = insert(:user, email: email)
          vault = insert(:vault, user: user)
          Engram.Fixtures.insert_note!(user, vault, path: "n#{i}.md", content: "# N#{i}")
        end

      # The fixture leaves index columns nil (content-stale); mark the second
      # note indexed at its content, with only a stale keyword version.
      Repo.update_all(
        from(n in Note,
          where: n.id == ^keyword.id,
          update: [set: [embed_hash: n.content_hash, dense_indexed_hash: n.content_hash]]
        ),
        [set: [chunker_version: Markdown.chunker_version(), keyword_version: nil]],
        skip_tenant_check: true
      )

      %{stale: stale, keyword: keyword}
    end)
  end

  # Runs on its own connection, so it waits on any row the sandbox
  # transaction still locks (a failing run whose sweep went through the app
  # pool). The lock timeout makes that a visible on_exit error instead of a
  # hang; the next run's setup deletes the leftovers.
  defp delete_committed! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        ids =
          from(u in Engram.Accounts.User,
            where: like(u.email, ^"#{@email_prefix}%"),
            select: u.id
          )

        # notes do not cascade from users.
        Repo.delete_all(from(n in Note, where: n.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(ids |> exclude(:select), skip_tenant_check: true)
      end)
    end)
  end

  test "sweeps every tenant through the maintenance pool, page by page", notes do
    # CONTROL: the app pool, as it runs here, sees none of them.
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Note, :count, skip_tenant_check: true) end)

    # The per-tenant fallback would also find them (it sets each tenant on
    # the app pool), so what tells the two apart: no `notes` query on Repo.
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      # The maintenance pool shares this telemetry prefix (same config): tell
      # them apart by repo.
      fn _e, _m, %{source: source, repo: repo, query: sql}, _c ->
        cond do
          self() != test_pid or source != "notes" -> :ok
          repo == Repo -> send(test_pid, :app_pool_notes_query)
          sql =~ ~r/^UPDATE/ -> send(test_pid, :maintenance_page)
          true -> :ok
        end
      end,
      nil
    )

    try do
      # One note per page, so each sweep must loop to find both tenants' work.
      assert :ok =
               as_prod_role_committing(fn ->
                 perform_job(ReconcileEmbeddings, %{"page" => 1})
               end)
    after
      :telemetry.detach(handler)
    end

    refute_received :app_pool_notes_query
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => notes.stale.id})
    assert_enqueued(worker: RefreshKeywordVectors, args: %{"note_id" => notes.keyword.id})

    # Each sweep: a full page, then an empty one that ends the loop.
    assert count_messages(:maintenance_page) == 4
  end

  defp count_messages(msg, n \\ 0) do
    receive do
      ^msg -> count_messages(msg, n + 1)
    after
      0 -> n
    end
  end
end
