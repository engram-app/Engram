defmodule Engram.Attachments.LocationRaceTest do
  @moduledoc """
  S6 step 6 (Engram#2523): a write and a rename racing on one attachment
  left under a folder moved without a cascade. On REAL connections (see
  `Engram.CheckpointInterleave`): in the sandbox every process shares one
  connection, so a row lock never blocks and the heal's fence is never hit.

  The rename (B/x.png -> B/y.png) holds the row, uncommitted. The write at
  B/x.png then reads the row as stale (stored A/x.png, shown B/x.png) and
  its fenced repoint waits on the row lock. Once the rename commits, the
  fence misses: the write must neither fail nor drag the renamed row back,
  and must land as a new file at B/x.png.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.{Attachments, CheckpointInterleave, Notes, Repo, Sync}
  alias Engram.Attachments.Attachment

  setup do
    CheckpointInterleave.checkout_real!()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user, id: user_id, email: "att-race-#{System.unique_integer([:positive])}@t.com")

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "AttRace", Ecto.UUID.generate())

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "A/x.png",
        "content_base64" => Base.encode64("old bytes")
      })

    cursor = Repo.with_tenant!(user.id, fn -> Engram.Vaults.raw_current_seq(vault.id) end)

    {:ok, {:ok, 1}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, "A", "B") end)

    %{user: user, vault: vault, att: att, cursor: cursor}
  end

  # A backend of this database waiting on a row lock (the write's repoint).
  defp await_lock_wait(tries \\ 100)
  defp await_lock_wait(0), do: flunk("the write never waited on the renamed row")

  defp await_lock_wait(tries) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    if n > 0, do: :ok, else: Process.sleep(50) && await_lock_wait(tries - 1)
  end

  test "a write at the shown path waits out a rename of the same row",
       %{user: u, vault: v, att: att, cursor: cursor} do
    test = self()

    rename =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.transaction(fn ->
          moved = Attachments.move_attachment(u, v, "B/x.png", "B/y.png")
          send(test, {:renamed, moved})

          receive do
            :commit -> moved
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive {:renamed, {:ok, %{id: id, path: "B/y.png"}}}, 10_000
    assert id == att.id

    write =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Attachments.upsert_attachment(u, v, %{
          "path" => "B/x.png",
          "content_base64" => Base.encode64("new bytes")
        })
      end)

    await_lock_wait()
    send(rename.pid, :commit)
    assert {:ok, {:ok, _}} = Task.await(rename, 15_000)
    assert {:ok, fresh} = Task.await(write, 15_000)

    assert fresh.id != att.id
    assert {:ok, %{id: ^id, content: "old bytes"}} = Attachments.get_attachment(u, v, "B/y.png")
    assert {:ok, %{content: "new bytes"}} = Attachments.get_attachment(u, v, "B/x.png")

    {:ok, listed} = Attachments.list_attachments(u, v)
    assert listed |> Enum.map(& &1.path) |> Enum.sort() == ["B/x.png", "B/y.png"]

    live =
      Repo.with_tenant!(u.id, fn ->
        Repo.aggregate(
          from(a in Attachment, where: a.vault_id == ^v.id and is_nil(a.deleted_at)),
          :count
        )
      end)

    assert live == 2

    feed =
      Sync.merged_changes_page(u, v, cursor, nil, 500, :all, nil, moved: false).page
      |> Enum.filter(&(&1.type == :attachment))

    refute Enum.any?(feed, &String.starts_with?(&1.path, "A/"))
  end
end
