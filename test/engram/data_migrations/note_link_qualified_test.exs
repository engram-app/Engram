defmodule Engram.DataMigrations.NoteLinkQualifiedTest do
  # The `NoteLinkQualified` ledger (O(1) folder rename plan S4.6, Engram#2523):
  # fills `note_links.qualified` on rows a previous release wrote (NULL), in
  # one paced chain (`BackfillNoteLinkQualified`), and closes on one clean
  # walk. Red before S4.6: neither the column nor the modules existed.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteLinkQualified
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Workers.BackfillNoteLinkQualified

  @content "[[Bare]] [[Folder/Pathed]] [x](../Up.md)"

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp links!(user, vault, path, content \\ @content) do
    source = Engram.Fixtures.insert_note!(user, vault, %{path: path})
    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))
    source
  end

  # What 0.84.0 leaves: no `qualified` at all.
  defp n_minus_1!, do: Repo.query!("UPDATE note_links SET qualified = NULL")

  defp qualified(source) do
    %{rows: rows} =
      Repo.query!(
        "SELECT qualified FROM note_links WHERE source_note_id = $1 ORDER BY position",
        [Ecto.UUID.dump!(source.id)]
      )

    List.flatten(rows)
  end

  defp run_chain(args \\ %{}, opts \\ [], hops \\ 1) do
    case BackfillNoteLinkQualified.hop(args, Keyword.put_new(opts, :pause_ms, 0)) do
      {:next, args} when hops < 100 -> run_chain(args, opts, hops + 1)
      other -> {other, hops}
    end
  end

  test "fills the rows a previous release left NULL, then closes", %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    other = Engram.Fixtures.user_with_dek_fixture() |> elem(1)
    b = links!(other, insert(:vault, user: other), "B.md", "[[x/y]] [[z]]")
    n_minus_1!()

    assert NoteLinkQualified.enabled?()
    assert {:more, _} = NoteLinkQualified.run_pass()
    assert [%{args: args}] = all_enqueued(worker: BackfillNoteLinkQualified)
    refute DataMigrations.done?(NoteLinkQualified.name(), NoteLinkQualified.version())

    # The walk that fixed rows starts a second walk, which is clean: done.
    assert {:done, 2} = run_chain(args)

    assert qualified(a) == [false, true, true]
    assert qualified(b) == [true, false]
    assert DataMigrations.done?(NoteLinkQualified.name(), NoteLinkQualified.version())
    assert NoteLinkQualified.run_pass() == :done
  end

  test "idempotent: a second walk writes nothing and changes nothing", %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    n_minus_1!()
    assert {:done, 2} = run_chain()
    before = Repo.query!("SELECT id, qualified FROM note_links ORDER BY id").rows

    assert {:done, 1} = run_chain()
    assert Repo.query!("SELECT id, qualified FROM note_links ORDER BY id").rows == before
    assert qualified(a) == [false, true, true]
  end

  test "rows already classified are left as they are", %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    # A deliberately wrong value: the backfill only fills NULLs, never re-derives.
    Repo.query!("UPDATE note_links SET qualified = true")
    assert {:done, 1} = run_chain()
    assert qualified(a) == [true, true, true]
  end

  test "a hop is bounded by its row cap and the next resumes at its cursor", %{
    user: u,
    vault: v
  } do
    a = links!(u, v, "A.md")
    n_minus_1!()

    assert {:next, next} =
             BackfillNoteLinkQualified.hop(%{}, max_rows: 1, batch_size: 1, pause_ms: 0)

    assert Enum.count(qualified(a), &is_nil/1) == 2
    assert {:done, _} = run_chain(next)
    assert qualified(a) == [false, true, true]
  end

  test "a row that never decrypts is classified qualified (the safe side), and the ledger closes",
       %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    n_minus_1!()

    Repo.query!(
      "UPDATE note_links SET target_text_ciphertext = '\\x0001'::bytea " <>
        "WHERE source_note_id = $1 AND position = 0",
      [Ecto.UUID.dump!(a.id)]
    )

    assert {:done, 2} = run_chain()
    # Position 0 is `[[Bare]]`: unreadable, so true; the S5 probe then queues
    # the rewrite job instead of skipping it.
    assert qualified(a) == [true, true, true]
    assert DataMigrations.done?(NoteLinkQualified.name(), NoteLinkQualified.version())
  end

  test "a user mid DEK rotation is left and holds the ledger open", %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    n_minus_1!()

    Repo.query!("UPDATE users SET dek_rotation_locked_at = now() WHERE id = $1", [
      Ecto.UUID.dump!(u.id)
    ])

    assert {:stopped, 1} = run_chain()
    assert qualified(a) == [nil, nil, nil]
    refute DataMigrations.done?(NoteLinkQualified.name(), NoteLinkQualified.version())
    # The fruitless walk is remembered: no new walk for a day.
    assert {:more, chains: 0, waiting: 1} = NoteLinkQualified.run_pass()
  end

  test "an older node in the cluster blocks the walk and the close", %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    n_minus_1!()

    behind = [
      peers: fn -> [:"old@10.0.0.9"] end,
      multicall: fn _peers -> [{:error, {:exception, :undef, []}}] end
    ]

    assert :stopped = BackfillNoteLinkQualified.hop(%{}, fleet: behind, pause_ms: 0)
    assert qualified(a) == [nil, nil, nil]
    refute DataMigrations.done?(NoteLinkQualified.name(), NoteLinkQualified.version())
  end

  test "the kill switch off runs no pass and stops the chain", %{user: u, vault: v} do
    a = links!(u, v, "A.md")
    n_minus_1!()
    Engram.ServiceConfig.put_override(:note_link_qualified_backfill, false)

    refute NoteLinkQualified.enabled?()
    assert :ok = perform_job(BackfillNoteLinkQualified, %{})
    assert [] = all_enqueued(worker: BackfillNoteLinkQualified)
    # A hop already running aborts before its next window.
    assert :stopped = BackfillNoteLinkQualified.hop(%{}, pause_ms: 0)
    assert qualified(a) == [nil, nil, nil]
  end

  test "run_pass does not start a second chain while one is in flight", %{user: u, vault: v} do
    links!(u, v, "A.md")
    n_minus_1!()
    assert {:more, _} = NoteLinkQualified.run_pass()
    assert {:more, _} = NoteLinkQualified.run_pass()
    assert [_] = all_enqueued(worker: BackfillNoteLinkQualified)
  end

  test "perform paces the chain: the successor is scheduled, not immediate", %{
    user: u,
    vault: v
  } do
    links!(u, v, "A.md")
    n_minus_1!()
    Engram.ServiceConfig.put_override(:note_link_qualified_backfill_max_rows, 1)

    assert :ok = perform_job(BackfillNoteLinkQualified, %{})
    assert [job] = all_enqueued(worker: BackfillNoteLinkQualified)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 30
  end

  describe "RLS" do
    test "control: in another tenant's context the heal reads and writes nothing", %{
      user: u,
      vault: v
    } do
      a = links!(u, v, "A.md")
      other = insert(:user)
      n_minus_1!()
      ids = Repo.query!("SELECT id::text FROM note_links").rows |> List.flatten()

      assert {0, false} =
               as_prod_role_committing(fn ->
                 BackfillNoteLinkQualified.heal_window(ids, %{repo: Repo, user_id: other.id})
               end)

      assert qualified(a) == [nil, nil, nil]
    end

    test "in the owner's tenant the heal writes the rows", %{user: u, vault: v} do
      a = links!(u, v, "A.md")
      n_minus_1!()
      ids = Repo.query!("SELECT id::text FROM note_links").rows |> List.flatten()

      assert {3, false} =
               as_prod_role_committing(fn ->
                 BackfillNoteLinkQualified.heal_window(ids, %{repo: Repo, user_id: u.id})
               end)

      assert qualified(a) == [false, true, true]
    end
  end
end
