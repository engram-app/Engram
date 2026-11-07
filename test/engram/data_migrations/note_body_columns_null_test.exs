defmodule Engram.DataMigrations.NoteBodyColumnsNullTest do
  @moduledoc """
  R8(b2) null batch: clears `notes.content_ciphertext` /
  `crdt_state_ciphertext` only where `note_bodies` holds the same envelope,
  keeps the nonces, never touches a drifted row, and refuses to run (stays
  open) while the copy trigger exists, the head trigger ignores the nonce,
  or an older node is connected. Per-tenant walk (self-host) here; the
  fleet walk and a held row lock are in the modules below.
  """
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.DataMigrations.NoteBodyColumnsNull, as: Null
  alias Engram.Notes
  alias Engram.Notes.CrdtCheckpoint
  alias Engram.Notes.NoteBody
  alias Engram.Repo
  alias Engram.Workers.DataMigrationsRunner
  alias Engram.Workers.ReencodeEnvelopes

  setup do
    IdWindows.reset_walk(Null.name())
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Null", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  def write!(u, v, path, content) do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => path, "content" => content}, actor: "api")
    note
  end

  def old_release_copy!(id), do: Engram.Fixtures.old_release_notes_copy!(id)

  defp doc_with(text) do
    doc = Yex.Doc.new()
    Yex.Text.insert(Yex.Doc.get_text(doc, "content"), 0, text)
    doc
  end

  def raw(id) do
    [row] =
      Repo.query!(
        "SELECT content_ciphertext, crdt_state_ciphertext, content_nonce, crdt_state_nonce FROM notes WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      ).rows

    row
  end

  def run_to_done(opts \\ []) do
    Enum.reduce_while(1..10, nil, fn _, _ ->
      case Null.run_pass(opts) do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  test "is registered after NoteSplit" do
    migrations = DataMigrationsRunner.migrations()

    assert Enum.find_index(migrations, &(&1 == Null)) ==
             Enum.find_index(migrations, &(&1 == Engram.DataMigrations.NoteSplit)) + 1
  end

  test "nulls the ciphertexts of rows in step, keeps nonces, bodies still read", %{
    user: u,
    vault: v
  } do
    a = write!(u, v, "a.md", "alpha")
    b = write!(u, v, "b.md", "beta")
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, b.id, doc_with("changed"))
    for n <- [a, b], do: old_release_copy!(n.id)
    assert [ct, st, _, _] = raw(a.id)
    assert is_binary(ct) and is_binary(st)
    before = for n <- [a, b], do: Repo.with_tenant!(u.id, fn -> NoteBody.get(n.id) end)

    assert run_to_done(batch: 1) == :done

    for {n, body} <- Enum.zip([a, b], before) do
      assert [nil, nil, cn, sn] = raw(n.id)
      assert {cn, sn} == {body.content_nonce, body.crdt_state_nonce}
      assert Repo.with_tenant!(u.id, fn -> NoteBody.get(n.id) end) == body
    end

    assert {:ok, %{content: "alpha"}} = Notes.get_note(u, v, "a.md")
    assert {:ok, %{content: text}} = Notes.get_note(u, v, "b.md")
    assert text =~ "changed"
    assert Engram.Fixtures.note_body_divergence(u.id) == []
  end

  test "never nulls a notes nonce the body does not hold, and stays open for it",
       %{user: u, vault: v} do
    ok = write!(u, v, "ok.md", "fine")
    drifted = write!(u, v, "new.md", "drifted nonce")
    for n <- [ok, drifted], do: old_release_copy!(n.id)

    # A notes nonce the body does not hold.
    Repo.query!("UPDATE notes SET content_nonce = $2 WHERE id = $1", [
      Ecto.UUID.dump!(drifted.id),
      <<1>> <> :crypto.strong_rand_bytes(12)
    ])

    [ct, _, cn, _] = raw(drifted.id)

    assert {:more, _} = Null.run_pass()
    assert {:more, _} = Null.run_pass()

    assert [nil, nil, _, _] = raw(ok.id)
    # The content column stays; the in-step CRDT column of the same row goes.
    assert [^ct, nil, ^cn, _] = raw(drifted.id)
  end

  test "a stale copy under the body's nonce is nulled and counted", %{user: u, vault: v} do
    n = write!(u, v, "same.md", "stale under its nonce")
    old_release_copy!(n.id)

    # Same nonce, other bytes: what a release-B write leaves.
    Repo.query!("UPDATE notes SET content_ciphertext = $2 WHERE id = $1", [
      Ecto.UUID.dump!(n.id),
      :crypto.strong_rand_bytes(48)
    ])

    _ = Engram.DataMigration.take_stats()
    assert run_to_done() == :done
    assert [nil, nil, _, _] = raw(n.id)
    assert {:ok, %{content: "stale under its nonce"}} = Notes.get_note(u, v, "same.md")
  end

  # Review HIGH-1: release B writes only the nonce, so every note it edits
  # keeps an old notes copy under a new nonce. The batch must still close.
  test "a 0.76-style row that release B then edits and checkpoints: done, both NULL",
       %{user: u, vault: v} do
    n = write!(u, v, "edited.md", "first")
    old_release_copy!(n.id)
    write!(u, v, "edited.md", "second")
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, n.id, doc_with("third"))
    [ct, st, _, _] = raw(n.id)
    assert is_binary(ct) and is_binary(st)

    assert run_to_done() == :done
    assert [nil, nil, cn, sn] = raw(n.id)
    assert is_binary(cn) and is_binary(sn)
    assert {:ok, %{content: text}} = Notes.get_note(u, v, "edited.md")
    assert text =~ "third"
  end

  test "a 0.76-style row that release B renames: done, both NULL", %{user: u, vault: v} do
    n = write!(u, v, "r.md", "body")
    old_release_copy!(n.id)
    assert {:ok, _} = Notes.rename_note(u, v, "r.md", "s.md")
    assert run_to_done() == :done
    assert [nil, nil, _, _] = raw(n.id)
    assert {:ok, %{content: "body"}} = Notes.get_note(u, v, "s.md")
  end

  test "a note with no body row yet is left until it has one", %{user: u, vault: v} do
    n = write!(u, v, "a.md", "x")
    old_release_copy!(n.id)
    Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [Ecto.UUID.dump!(n.id)])
    assert {:more, _} = Null.run_pass()
    assert [ct, _, _, _] = raw(n.id)
    assert is_binary(ct)
  end

  test "a row already NULL is no work: the walk is done", %{user: u, vault: v} do
    write!(u, v, "a.md", "x")
    assert Null.run_pass() == :done
  end

  # The write fences compare the notes nonce, so they still trip once the
  # ciphertexts are gone: a compare-and-set against a stale read loses.
  test "write fences still trip after nulling", %{user: u, vault: v} do
    n = write!(u, v, "a.md", "first")
    old_release_copy!(n.id)
    assert run_to_done() == :done
    stale = Repo.with_tenant!(u.id, fn -> NoteBody.get(n.id) end)
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, n.id, doc_with("moved on"))
    refute Enum.at(raw(n.id), 3) == stale.crdt_state_nonce
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state("stale", u, n.id)

    assert {0, _} =
             Repo.with_tenant!(u.id, fn ->
               ReencodeEnvelopes.write_row(
                 :notes_crdt_state,
                 n.id,
                 {stale.crdt_state_ciphertext, stale.crdt_state_nonce},
                 ct,
                 nonce
               )
             end)

    assert {:ok, %{content: text}} = Notes.get_note(u, v, "a.md")
    assert text =~ "moved on"
  end

  describe "guards: blocked, walks nothing, stays open" do
    setup %{user: u, vault: v} do
      n = write!(u, v, "a.md", "x")
      old_release_copy!(n.id)
      %{id: n.id}
    end

    defp assert_blocked!(id, opts \\ []) do
      assert Null.run_pass(opts) == {:more, rows: 0, blocked: 1}
      assert [ct, _, _, _] = raw(id)
      assert is_binary(ct)
      refute Engram.DataMigrations.done?(Null.name(), Null.version())
    end

    test "the notes_sync_body copy trigger exists", %{id: id} do
      Repo.query!(
        "CREATE FUNCTION notes_sync_body() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$"
      )

      Repo.query!(
        "CREATE TRIGGER notes_sync_body AFTER UPDATE ON notes FOR EACH ROW EXECUTE FUNCTION notes_sync_body()"
      )

      assert Null.blocker() == :copy_trigger_present
      assert_blocked!(id)
    end

    test "the head trigger does not fire on crdt_state_nonce", %{id: id} do
      Repo.query!("""
      CREATE OR REPLACE TRIGGER notes_crdt_head_invalidate
      BEFORE UPDATE OF crdt_state_ciphertext ON notes FOR EACH ROW
      WHEN (NEW.crdt_state_ciphertext IS DISTINCT FROM OLD.crdt_state_ciphertext)
      EXECUTE FUNCTION notes_null_crdt_head()
      """)

      assert Null.blocker() == :head_trigger_not_on_nonce
      assert_blocked!(id)
    end

    test "the head trigger is missing", %{id: id} do
      Repo.query!("DROP TRIGGER notes_crdt_head_invalidate ON notes")
      assert Null.blocker() == :head_trigger_not_on_nonce
      assert_blocked!(id)
    end

    test "a connected node older than release A (no NoteBody.put!/2)", %{id: id} do
      old = [
        peers: fn -> [:"engram@10.0.0.9"] end,
        multicall: fn _ -> [{:ok, false}] end
      ]

      assert Null.blocker(fleet: old) == {:peer_behind, :"engram@10.0.0.9"}
      assert_blocked!(id, fleet: old)

      new = [peers: fn -> [:"engram@10.0.0.9"] end, multicall: fn _ -> [{:ok, true}] end]
      assert Null.blocker(fleet: new) == nil
      assert run_to_done(fleet: new) == :done
      assert [nil, nil, _, _] = raw(id)
    end

    test "an unreachable node", %{id: id} do
      down = [peers: fn -> [:"engram@10.0.0.9"] end, multicall: fn _ -> [{:error, :timeout}] end]
      assert Null.blocker(fleet: down) == {:peer_unreachable, :"engram@10.0.0.9"}
      assert_blocked!(id, fleet: down)
    end

    test "the real probe: this node and a single-node self-host pass" do
      # No peers, no cluster query: a self-host is one node.
      assert Null.blocker() == nil

      # The probe the multicall makes, against this node.
      assert [{:ok, true}] =
               :erpc.multicall([node()], :erlang, :function_exported, [NoteBody, :put!, 2], 5_000)
    end
  end

  describe "kill switch" do
    test "note_body_columns_null off: the runner runs no pass", %{user: u, vault: v} do
      n = write!(u, v, "a.md", "x")
      old_release_copy!(n.id)
      Engram.ServiceConfig.put_override(:note_body_columns_null, false)

      refute Null.enabled?()
      assert DataMigrationsRunner.run(Null) == :skipped
      assert [ct, _, _, _] = raw(n.id)
      assert is_binary(ct)
      refute Engram.DataMigrations.done?(Null.name(), Null.version())
    end

    test "on by default" do
      assert Null.enabled?()
    end
  end

  describe "per-pass cap (note_body_columns_null_max_fixed)" do
    import ExUnit.CaptureLog

    # 700 notes with the `notes` copies an older release left, in a few
    # statements.
    defp copies!(u, v, n) do
      _ = Engram.Fixtures.insert_notes!(u, v, for(i <- 1..n, do: %{path: "cap/#{i}.md"}))

      Repo.query!(
        """
        UPDATE notes AS n SET content_ciphertext = substring(b.content_ct FROM 14)
        FROM note_bodies AS b WHERE b.note_id = n.id AND n.user_id = $1
        """,
        [Ecto.UUID.dump!(u.id)]
      )
    end

    defp nulled(u) do
      [[n]] =
        Repo.query!(
          "SELECT count(*)::int FROM notes WHERE user_id = $1 AND kind = 'note' AND content_ciphertext IS NULL",
          [Ecto.UUID.dump!(u.id)]
        ).rows

      n
    end

    test "an override of 400 fixes at most 400 plus one window in a pass", %{user: u, vault: v} do
      copies!(u, v, 700)
      Engram.ServiceConfig.put_override(:note_body_columns_null_max_fixed, 400)

      assert {:more, _} = Null.run_pass()
      assert nulled(u) in 400..600
    end

    test "an invalid override falls back to 10,000, with a warning", %{user: u, vault: v} do
      copies!(u, v, 700)
      Engram.ServiceConfig.put_override(:note_body_columns_null_max_fixed, -5)

      log = capture_log([level: :warning], fn -> Null.run_pass() end)
      assert nulled(u) == 700
      assert log =~ "note_body_columns_null_max_fixed"
    end

    test "run_pass/1's max_fixed: wins over the override", %{user: u, vault: v} do
      copies!(u, v, 700)
      Engram.ServiceConfig.put_override(:note_body_columns_null_max_fixed, 10_000)

      assert {:more, _} = Null.run_pass(max_fixed: 200)
      assert nulled(u) in 200..400
    end

    test "is overridable at runtime" do
      assert :note_body_columns_null_max_fixed in Engram.ServiceConfig.Overrides.keys()
    end
  end
end

defmodule Engram.DataMigrations.NoteBodyColumnsNullLockTest do
  @moduledoc """
  The null batch's SKIP LOCKED path, on REAL connections
  (`Engram.CheckpointInterleave`): a row a writer holds is skipped, not
  nulled, and the pass stays open until a later pass takes it.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.Backfill.IdWindows
  alias Engram.CheckpointInterleave
  alias Engram.DataMigrations.NoteBodyColumnsNull, as: Null
  alias Engram.DataMigrations.NoteBodyColumnsNullTest, as: T
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()
    IdWindows.reset_walk(Null.name())
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user, id: user_id, email: "null-lock-#{System.unique_integer([:positive])}@t.co")

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "NullLock", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "a row a writer holds is skipped and keeps the pass open", %{user: u, vault: v} do
    n = T.write!(u, v, "l.md", "x")
    {:ok, _} = Repo.with_tenant(u.id, fn -> T.old_release_copy!(n.id) end)
    id = Ecto.UUID.dump!(n.id)
    test = self()

    holder =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(u.id, fn ->
          Repo.query!("SELECT id FROM notes WHERE id = $1 FOR UPDATE", [id])
          send(test, :locked)

          receive do
            :release -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000
    assert {:more, _} = Null.run_pass()
    assert {:more, _} = Null.run_pass()
    {:ok, [ct, _, _, _]} = Repo.with_tenant(u.id, fn -> T.raw(n.id) end)
    assert is_binary(ct)

    send(holder.pid, :release)
    Task.await(holder)

    assert T.run_to_done() == :done
    assert {:ok, [nil, nil, _, _]} = Repo.with_tenant(u.id, fn -> T.raw(n.id) end)
  end
end

defmodule Engram.DataMigrations.NoteBodyColumnsNullFleetTest do
  @moduledoc """
  The fleet walk (SaaS): through the maintenance pool, connected as the
  real `engram_maintenance` role (no SUPERUSER, no BYPASSRLS), across two
  tenants in one walk. A missing grant or policy turns this red. Fixtures
  are COMMITTED (the pool is a second connection) and removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.NoteBodyColumnsNull, as: Null
  alias Engram.DataMigrations.NoteBodyColumnsNullTest, as: T
  alias Engram.Repo
  alias Engram.Repo.Maintenance

  setup do
    IdWindows.reset_walk(Null.name())

    config =
      Keyword.merge(Repo.config(),
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET SESSION AUTHORIZATION engram_maintenance", []]}
      )

    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Fleet#{i}", Ecto.UUID.generate())
          note = T.write!(user, vault, "f#{i}.md", "fleet #{i}")
          T.old_release_copy!(note.id)
          {user, note}
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for {user, _} <- made do
          Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
            skip_tenant_check: true
          )

          Repo.delete!(user, skip_tenant_check: true)
          Repo.delete_all(from(j in Oban.Job, where: j.args["user_id"] == ^user.id))
        end
      end)
    end)

    %{made: made}
  end

  test "one walk nulls every tenant's in-step rows", %{made: made} do
    assert T.run_to_done() == :done

    for {_user, note} <- made do
      assert [nil, nil, cn, sn] = Sandbox.unboxed_run(Repo, fn -> T.raw(note.id) end)
      assert is_binary(cn) and is_binary(sn)
    end
  end
end
