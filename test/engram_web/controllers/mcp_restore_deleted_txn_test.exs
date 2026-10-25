defmodule EngramWeb.McpRestoreDeletedTxnTest do
  @moduledoc """
  #609 review H1: `restore_deleted` must run OUTSIDE the MCP request
  transaction, through the real controller dispatch. Inside it, the
  restore's per-chunk transactions collapse into one: a large undo holds
  the vault lock for its whole length, its index claims land inside an open
  transaction, its broadcasts fire before the commit, and a failure rolls
  back everything, so a retry starts from zero.

  Real commits are the only way to see that, so this runs outside the
  sandbox (cleanup on exit) with one note per chunk:

    * while chunk 2 runs, a SECOND connection already sees chunk 1's note
      restored (under one request transaction it would still be in trash);
    * chunk 2's note is damaged (content will not decrypt): it is skipped as
      `unreadable` and everything after it still comes back, so one damaged
      note cannot stop every retry at the same row.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.MCP.Tools
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo
  alias EngramWeb.McpController

  setup do
    prev = Application.get_env(:engram, :restore_chunk)
    Application.put_env(:engram, :restore_chunk, 1)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :restore_chunk, prev),
        else: Application.delete_env(:engram, :restore_chunk)
    end)

    {user, vault} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
        {user, Engram.Fixtures.insert_vault!(user, "Restore")}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        uid = Ecto.UUID.dump!(user.id)
        Repo.query!("DELETE FROM oban_jobs WHERE args->>'user_id' = $1", [user.id])
        Repo.query!("DELETE FROM notes WHERE user_id = $1", [uid])
        Repo.query!("DELETE FROM vaults WHERE user_id = $1", [uid])
        Repo.query!("DELETE FROM users WHERE id = $1", [uid])
      end)
    end)

    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp corrupt_content!(id) do
    row = Repo.get!(Note, id, skip_tenant_check: true)
    last = byte_size(row.content_ciphertext) - 1
    <<head::binary-size(last), byte>> = row.content_ciphertext

    {1, _} =
      Repo.update_all(
        from(n in Note, where: n.id == ^id),
        [set: [content_ciphertext: <<head::binary, Bitwise.bxor(byte, 0xFF)>>]],
        skip_tenant_check: true
      )
  end

  defp call(tool_name, user, vault, args) do
    {:ok, tool} = Tools.get(tool_name)
    {result, _status, _bytes} = McpController.run_tool_handler(tool, user, vault, args)
    result
  end

  defp deleted_at_elsewhere(id) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.one(from(n in Note, where: n.id == ^id, select: n.deleted_at),
          skip_tenant_check: true
        )
      end)
    end)
    |> Task.await(5_000)
  end

  test "chunks commit one by one; a damaged note is skipped, the rest restored", %{
    user: user,
    vault: vault
  } do
    test_pid = self()
    handler = {__MODULE__, make_ref()}
    loads = :counters.new(1, [])

    Sandbox.unboxed_run(Repo, fn ->
      a = put_note(user, vault, "Docs/a.md")
      b = put_note(user, vault, "Docs/b.md")
      c = put_note(user, vault, "Docs/c.md")

      {:ok, %{"structuredContent" => %{"delete_op_id" => op}}} =
        call("delete_folder", user, vault, %{"folder" => "Docs", "recursive" => true})

      corrupt_content!(b.id)

      # On each restore chunk's load (the only op-id query with an id list).
      # At chunk 2, look at chunk 1's note from another connection.
      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        fn _, _, meta, _ ->
          q = meta[:query] || ""

          if self() == test_pid and q =~ "delete_op_id" and q =~ "ANY(" do
            :counters.add(loads, 1, 1)

            if :counters.get(loads, 1) == 2,
              do: send(test_pid, {:seen_elsewhere, deleted_at_elsewhere(a.id)})
          end
        end,
        nil
      )

      in_txn_claims = :counters.new(1, [])
      claim_handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        claim_handler,
        [:engram, :crdt, :index_in_transaction],
        fn _, _, _, _ -> :counters.add(in_txn_claims, 1, 1) end,
        nil
      )

      log =
        capture_log(fn ->
          assert {:ok, %{"structuredContent" => result}} =
                   call("restore_deleted", user, vault, %{"op_id" => op})

          assert result["notes"] == 2
          assert [%{"path" => "Docs/b.md", "reason" => "unreadable"}] = result["skipped"]
        end)

      :telemetry.detach(handler)
      :telemetry.detach(claim_handler)

      assert log =~ "decrypt_failed"
      assert_received {:seen_elsewhere, nil}, "chunk 1 was not committed while chunk 2 ran"
      assert :counters.get(in_txn_claims, 1) == 0, "the index claim ran inside a transaction"

      assert is_nil(Repo.get!(Note, a.id, skip_tenant_check: true).deleted_at)
      assert Repo.get!(Note, b.id, skip_tenant_check: true).deleted_at
      assert is_nil(Repo.get!(Note, c.id, skip_tenant_check: true).deleted_at)
    end)
  end
end
