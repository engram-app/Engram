defmodule Engram.Folders.CascadeLogTest do
  # A folder op that falls back to the cascade logs ONE line naming the branch
  # that decided it (`WriteStop.log_cascade/3`, emitted by `Folders.rename/5`
  # after the claim retries settle), with hashed ids only. The op's own
  # behaviour is pinned by `write_stop_test.exs`; these assert the reason the
  # uncascaded leg returns and the line the op writes.
  use EngramWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Engram.{Crypto, Folders, Notes, Repo, ServiceConfig}
  alias Engram.Crypto.HMAC

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)

    for i <- 1..3, do: put!(user, vault, "A/n#{i}.md")
    other = put!(user, vault, "Other/o.md")

    # config/test.exs sets :warning.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    %{user: user, vault: vault, other: other}
  end

  defp put!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "n"}, actor: "api")

    note
  end

  defp sql!(sql, params), do: Repo.query!(sql, params)

  # The uncascaded leg called directly, as `Folders.notes_leg/5` does.
  defp uncascaded(user, vault, old, new) do
    Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, old, new) end)
  end

  defp rename_log(user, vault, old, new) do
    capture_log([level: :info], fn -> assert {:ok, _} = Folders.rename(user, vault, old, new) end)
  end

  defp lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "folder_op cascade"))

  describe "the reason the uncascaded leg returns" do
    test "no_old_row: nothing at the old path", %{user: u, vault: v} do
      assert {:ok, {:cascade, :no_old_row}} = uncascaded(u, v, "Nope", "Elsewhere")
    end

    test "new_folder_exists: a live folder already at the target", %{user: u, vault: v} do
      assert {:ok, {:cascade, :new_folder_exists}} = uncascaded(u, v, "A", "Other")
    end

    test "no_op: the same path", %{user: u, vault: v} do
      assert {:ok, {:cascade, :no_op}} = uncascaded(u, v, "A", "A")
    end

    test "empty: a folder row with nothing under it", %{user: u, vault: v} do
      sql!("DELETE FROM notes WHERE vault_id = $1 AND kind = 'note'", [Ecto.UUID.dump!(v.id)])

      # `Other` and `A` keep their folder rows; every note is gone.
      assert {:ok, {:cascade, :empty}} = uncascaded(u, v, "A", "B")
    end

    test "not_derivable: a note under it with a stale name stamp", %{user: u, vault: v} do
      sql!("UPDATE notes SET name_stamp = NULL WHERE vault_id = $1", [Ecto.UUID.dump!(v.id)])
      assert {:ok, {:cascade, :not_derivable}} = uncascaded(u, v, "A", "B")
    end

    test "drift: a placed note elsewhere in the vault has no folder reference",
         %{user: u, vault: v, other: other} do
      sql!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [Ecto.UUID.dump!(other.id)])
      assert {:ok, {:cascade, :drift}} = uncascaded(u, v, "A", "B")
    end

    test "unkeyed: a note the name-key trigger cannot key", %{user: u, vault: v} do
      sql!("UPDATE notes SET name_ci_hmac = NULL, name_key = NULL WHERE vault_id = $1", [
        Ecto.UUID.dump!(v.id)
      ])

      assert {:ok, {:cascade, :unkeyed}} = uncascaded(u, v, "A", "B")
    end

    test "merge_raced: a folder appears at the target during the locked move",
         %{user: u, vault: v} do
      Engram.CheckpointInterleave.put_hook(fn
        :folder_move_locked -> {:ok, _} = Folders.create_markers(u, v, ["B"])
        _ -> :ok
      end)

      assert {:ok, {:cascade, :merge_raced}} = uncascaded(u, v, "A", "B")
    end

    test "raced: a note is written under the folder after the scan", %{user: u, vault: v} do
      Engram.CheckpointInterleave.put_hook(fn
        :folder_move_locked -> put!(u, v, "A/late.md")
        _ -> :ok
      end)

      assert {:ok, {:cascade, :raced}} = uncascaded(u, v, "A", "B")
    end

    test "a served uncascaded move returns the count", %{user: u, vault: v} do
      assert {:ok, {:ok, n}} = uncascaded(u, v, "A", "B")
      assert n > 0
    end
  end

  describe "the line a folder op writes" do
    test "stop_off: the write stop is off, ids hashed", %{user: u, vault: v} do
      ServiceConfig.put_override(:folder_write_stop, false)

      assert [line] = lines(rename_log(u, v, "A", "B"))
      assert line =~ "reason=stop_off"
      assert line =~ HMAC.hash_user_id(u.id)
      assert line =~ HMAC.hash_id(v.id)
      refute line =~ u.id
      refute line =~ v.id
      refute line =~ "A/"
    end

    test "not_derivable cascades and logs its reason once", %{user: u, vault: v} do
      sql!("UPDATE notes SET name_stamp = NULL WHERE vault_id = $1", [Ecto.UUID.dump!(v.id)])
      assert [line] = lines(rename_log(u, v, "A", "B"))
      assert line =~ "reason=not_derivable"
    end

    test "a served uncascaded move logs nothing", %{user: u, vault: v} do
      assert lines(rename_log(u, v, "A", "B")) == []
    end

    test "an op whose claims go stale and reruns logs ONE line", %{user: u, vault: v} do
      sql!("UPDATE notes SET name_stamp = NULL WHERE vault_id = $1", [Ecto.UUID.dump!(v.id)])
      counter = :counters.new(1, [])

      # A note lands in `A` after the claim, before the transaction: the
      # claims are stale, so the whole attempt reruns (both attempts cascade).
      Engram.CheckpointInterleave.put_hook(fn
        :folder_claimed ->
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) == 1, do: put!(u, v, "A/late.md")
          :ok

        _ ->
          :ok
      end)

      log = rename_log(u, v, "A", "B")
      assert :counters.get(counter, 1) == 2, "the op must have retried"
      assert [line] = lines(log)
      assert line =~ "reason=not_derivable"
    end
  end
end
