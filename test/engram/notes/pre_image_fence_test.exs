defmodule Engram.Notes.PreImageFenceTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Crypto, Fixtures, Notes, Repo, Vaults}
  alias Engram.Notes.{Note, PreImageFence}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "PreImageFence", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "before"}, actor: "api")

    %{user: user, vault: vault, note: note}
  end

  # A row as the 2026-07 wipe left it: content, no CRDT state.
  defp wipe_state!(user, id) do
    Repo.with_tenant!(user.id, fn ->
      Fixtures.write_note_body!(id, crdt_state_ciphertext: nil, crdt_state_nonce: nil)
    end)
  end

  # Case B drift: the body keeps its state, `notes` holds a DIFFERENT nonce.
  # No write can pass the fence, and nothing can tell which copy is right.
  defp drift_crdt_nonce!(user, id) do
    assert {:ok, %{crdt_state_nonce: n}} =
             Repo.with_tenant(user.id, fn -> Fixtures.raw_note!(id) end)

    assert is_binary(n), "case B needs a row with state"
    set_notes_nonce!(id)
  end

  # Case A drift: the body has no state, `notes` keeps a nonce. Repairable:
  # the body is what every reader sees.
  defp case_a!(user, id) do
    wipe_state!(user, id)
    set_notes_nonce!(id)
  end

  defp set_notes_nonce!(id) do
    Repo.update_all(
      from(n in Note, where: n.id == ^id),
      [set: [crdt_state_nonce: :crypto.strong_rand_bytes(12)]],
      skip_tenant_check: true
    )
  end

  defp drifted?(user, id) do
    {:ok, ids} = Repo.with_tenant(user.id, fn -> Engram.Notes.NoteBody.drift_ids(Repo, [id]) end)
    ids != []
  end

  # The fence lock is the only FOR UPDATE that filters on the state nonce
  # (`IS NULL` or `=`, whichever the pre-image needs).
  defp fence_locks(fun) do
    test_pid = self()
    handler = "fence-lock-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      fn _, _, %{query: q}, _ ->
        if q =~ "FOR UPDATE" and q =~ ~s("crdt_state_nonce"),
          do: send(test_pid, :fence_lock)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    count(:fence_lock)
  end

  defp count(msg, n \\ 0) do
    receive do
      ^msg -> count(msg, n + 1)
    after
      0 -> n
    end
  end

  test "a REST write to a row WITH state takes no extra lock: its filters fence it", ctx do
    %{user: user, vault: vault} = ctx

    locks =
      fence_locks(fn ->
        assert {:ok, _} =
                 Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "after"},
                   actor: "api"
                 )
      end)

    assert locks == 0
  end

  test "a REST write to a stateless row takes exactly one fence lock", ctx do
    %{user: user, vault: vault, note: note} = ctx
    wipe_state!(user, note.id)

    locks =
      fence_locks(fn ->
        assert {:ok, _} =
                 Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "after"},
                   actor: "api"
                 )
      end)

    assert locks == 1
  end

  test "report_drift looks at the CRDT nonce copies only", ctx do
    %{user: user, note: note} = ctx

    # Content-nonce drift does not affect the fence: not reported.
    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [set: [content_nonce: :crypto.strong_rand_bytes(12)]],
      skip_tenant_check: true
    )

    {:ok, drifted?} =
      Repo.with_tenant(user.id, fn -> PreImageFence.report_drift(note.id, :rest) end)

    refute drifted?

    drift_crdt_nonce!(user, note.id)

    {:ok, drifted?} =
      Repo.with_tenant(user.id, fn -> PreImageFence.report_drift(note.id, :rest) end)

    assert drifted?
  end

  test "a REST write on a row with drifted CRDT nonces fails loudly, not as a conflict", ctx do
    %{user: user, vault: vault, note: note} = ctx
    drift_crdt_nonce!(user, note.id)

    test_pid = self()
    handler = "fence-drift-rest-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :crdt, :checkpoint_fence_drift],
      fn _, m, meta, _ -> send(test_pid, {:fence_drift, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :crdt_state_drift} =
                 Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "after"},
                   actor: "api"
                 )
      end)

    assert_received {:fence_drift, %{count: 1}, %{writer: :rest, outcome: :unrepaired}}
    assert log =~ "crdt fence drift"
  end

  test "a probe that errors is contained: the caller's transaction stays usable", ctx do
    %{user: user, note: note} = ctx
    drift_crdt_nonce!(user, note.id)

    # A probe statement that fails IN POSTGRES (division by zero). Without
    # the savepoint that failure aborts the whole transaction (25P02), so the
    # caller's next statement, and its retry signal, would be lost.
    Application.put_env(
      :engram,
      :crdt_drift_probe_fault_sql,
      "SELECT 1 / 0 WHERE $1::uuid IS NOT NULL"
    )

    on_exit(fn -> Application.delete_env(:engram, :crdt_drift_probe_fault_sql) end)

    {:ok, after_probe} =
      Repo.with_tenant(user.id, fn ->
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            refute PreImageFence.report_drift(note.id, :checkpoint)
          end)

        assert log =~ "crdt fence drift check failed"
        %{rows: [[1]]} = Repo.query!("SELECT 1")
        :usable
      end)

    assert after_probe == :usable
  end

  defp attach_drift do
    test_pid = self()
    handler = "fence-drift-move-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :crdt, :checkpoint_fence_drift],
      fn _, m, meta, _ -> send(test_pid, {:fence_drift, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "a rename on a drifted row reports drift as a move", ctx do
    %{user: user, vault: vault, note: note} = ctx
    drift_crdt_nonce!(user, note.id)
    attach_drift()

    ExUnit.CaptureLog.capture_log(fn -> Notes.rename_note(user, vault, "f.md", "g.md") end)
    assert_received {:fence_drift, %{count: 1}, %{writer: :move, outcome: :unrepaired}}
  end

  test "a resurrecting id-keyed move on a drifted row reports drift as a move", ctx do
    %{user: user, vault: vault, note: note} = ctx
    # A TOMBSTONED id at a new path takes the id-keyed move (resurrect) leg.
    :ok = Notes.delete_note(user, vault, "f.md")
    drift_crdt_nonce!(user, note.id)
    attach_drift()

    ExUnit.CaptureLog.capture_log(fn ->
      Notes.upsert_note(
        user,
        vault,
        %{"id" => note.id, "path" => "h.md", "content" => "before"},
        actor: "api"
      )
    end)

    assert_received {:fence_drift, %{count: 1}, %{writer: :move, outcome: :unrepaired}}
  end

  describe "case A (notes keeps a nonce the body has no state for) repairs itself" do
    test "a REST write succeeds and leaves the row consistent", ctx do
      %{user: user, vault: vault, note: note} = ctx
      case_a!(user, note.id)
      assert drifted?(user, note.id)
      attach_drift()

      assert {:ok, _} =
               Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "after"},
                 actor: "api"
               )

      assert_received {:fence_drift, %{count: 1}, %{writer: :rest, outcome: :repaired_a}}
      refute drifted?(user, note.id)
      assert {:ok, %{content: "after"}} = Notes.get_note_by_id(user, vault, note.id)
    end

    test "a rename works", ctx do
      %{user: user, vault: vault, note: note} = ctx
      case_a!(user, note.id)
      attach_drift()

      assert {:ok, _} = Notes.rename_note(user, vault, "f.md", "g.md")
      assert_received {:fence_drift, %{count: 1}, %{writer: :move, outcome: :repaired_a}}
      assert {:ok, %{path: "g.md"}} = Notes.get_note_by_id(user, vault, note.id)
    end

    test "a resurrecting id-keyed move works", ctx do
      %{user: user, vault: vault, note: note} = ctx
      :ok = Notes.delete_note(user, vault, "f.md")
      case_a!(user, note.id)
      attach_drift()

      assert {:ok, moved} =
               Notes.upsert_note(
                 user,
                 vault,
                 %{"id" => note.id, "path" => "h.md", "content" => "before"},
                 actor: "api"
               )

      assert moved.path == "h.md"
      assert_received {:fence_drift, %{count: 1}, %{writer: :move, outcome: :repaired_a}}
    end

    test "the repair log names the note by its HMAC, never the raw id", ctx do
      %{user: user, vault: vault, note: note} = ctx
      case_a!(user, note.id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "after"},
              actor: "api"
            )
        end)

      assert log =~ "crdt fence drift repaired note=#{Engram.Crypto.HMAC.hash_id(note.id)} case=a"
      refute log =~ note.id
    end
  end
end
