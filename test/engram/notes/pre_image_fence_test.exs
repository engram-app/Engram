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

  # Drift: the body has no state, `notes` keeps a nonce.
  defp drift_crdt_nonce!(user, id) do
    wipe_state!(user, id)

    Repo.update_all(
      from(n in Note, where: n.id == ^id),
      [set: [crdt_state_nonce: :crypto.strong_rand_bytes(12)]],
      skip_tenant_check: true
    )
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

    assert_received {:fence_drift, %{count: 1}, %{writer: :rest}}
    assert log =~ "crdt fence drift"
  end
end
