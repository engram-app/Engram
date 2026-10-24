defmodule Engram.AttachmentsLockOrderTest do
  @moduledoc """
  One lock order for every attachment write that takes both: the vault row
  (the seq counter) first, then attachment rows (#2159 review).

  An upload or delete takes the vault lock (`next_seq!`) and then writes the
  attachment row. A batch move that locked its source rows first and asked
  for the vault lock second formed a cycle with them: Postgres aborts one
  side with 40P01 after `deadlock_timeout`.

  `Engram.DataCase` runs everything on one sandbox connection, where row
  locks never block, so this checks out with `sandbox: false` (see
  `Engram.OAuthRotationRaceTest`): writes commit and locks really wait. The
  rows outlive the test, hence the cleanup. Determinism comes from the
  locks, not timing: a holder takes the vault lock, the move is started and
  observed blocked in `pg_stat_activity`, and only then does the holder
  write the attachment row the move wants.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Attachments
  alias Engram.Repo

  setup do
    real_checkout!()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    on_exit(fn -> cleanup(user.id) end)

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "Docs/a.png",
        "content_base64" => Base.encode64("bytes")
      })

    %{user: user, vault: vault, att: att}
  end

  defp real_checkout! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  defp cleanup(user_id) do
    real_checkout!()
    uid = Ecto.UUID.dump!(user_id)
    Repo.query!("DELETE FROM oban_jobs WHERE args->>'user_id' = $1", [user_id])
    Repo.query!("DELETE FROM attachments WHERE user_id = $1", [uid])
    Repo.query!("DELETE FROM vaults WHERE user_id = $1", [uid])
    Repo.query!("DELETE FROM users WHERE id = $1", [uid])
  end

  defp lock_waiters do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    n
  end

  defp await_lock_waiter(deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      lock_waiters() >= 1 -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("the move never blocked")
      true -> Process.sleep(10) && await_lock_waiter(deadline)
    end
  end

  test "a batch move and an upload-shaped write on its file both complete", ctx do
    %{user: user, vault: vault, att: att} = ctx
    test_pid = self()

    # Holds the vault seq lock, like an upload between next_seq! and its row
    # write; then writes the attachment row the move is about to take.
    holder =
      Task.async(fn ->
        real_checkout!()

        Repo.transaction(fn ->
          Repo.query!("UPDATE vaults SET change_seq = change_seq + 1 WHERE id = $1", [
            Ecto.UUID.dump!(vault.id)
          ])

          send(test_pid, :vault_locked)
          receive do: (:write_row -> :ok)

          Repo.query!("UPDATE attachments SET updated_at = now() WHERE id = $1", [
            Ecto.UUID.dump!(att.id)
          ])
        end)
      end)

    assert_receive :vault_locked, 5_000

    mover =
      Task.async(fn ->
        real_checkout!()
        Attachments.batch_move(user, vault, ["Docs/a.png"], "Archive")
      end)

    await_lock_waiter()
    send(holder.pid, :write_row)

    assert {:ok, _} = Task.await(holder, 15_000)
    assert {:ok, %{moved: 1}} = Task.await(mover, 15_000)
  end
end
