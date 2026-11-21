defmodule Engram.Folders.CascadeLogTest do
  # A folder op that falls back to the cascade logs ONE line naming the branch
  # that decided it (`WriteStop.log_cascade/3`), with hashed ids only. The op's
  # own behaviour is pinned by `write_stop_test.exs`; these assert the line.
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
    capture_log([level: :info], fn ->
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, old, new) end)
    end)
  end

  defp lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "folder_op cascade"))

  test "stop_off: the write stop is off", %{user: u, vault: v} do
    ServiceConfig.put_override(:folder_write_stop, false)

    log = capture_log([level: :info], fn -> assert {:ok, _} = Folders.rename(u, v, "A", "B") end)

    assert [line] = lines(log)
    assert line =~ "reason=stop_off"
    assert line =~ HMAC.hash_user_id(u.id)
    assert line =~ HMAC.hash_id(v.id)
    refute line =~ u.id
    refute line =~ v.id
    refute line =~ "A/"
  end

  test "no_old_row: nothing at the old path", %{user: u, vault: v} do
    assert [line] = lines(uncascaded(u, v, "Nope", "Elsewhere"))
    assert line =~ "reason=no_old_row"
  end

  test "new_folder_exists: a live folder already at the target", %{user: u, vault: v} do
    assert [line] = lines(uncascaded(u, v, "A", "Other"))
    assert line =~ "reason=new_folder_exists"
  end

  test "not_derivable: a note under it with a stale name stamp", %{user: u, vault: v} do
    sql!("UPDATE notes SET name_stamp = NULL WHERE vault_id = $1", [Ecto.UUID.dump!(v.id)])
    assert [line] = lines(uncascaded(u, v, "A", "B"))
    assert line =~ "reason=not_derivable"
  end

  test "drift: a placed note elsewhere in the vault has no folder reference",
       %{user: u, vault: v, other: other} do
    sql!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [Ecto.UUID.dump!(other.id)])
    assert [line] = lines(uncascaded(u, v, "A", "B"))
    assert line =~ "reason=drift"
  end

  test "unkeyed: a note the name-key trigger cannot key", %{user: u, vault: v} do
    sql!("UPDATE notes SET name_ci_hmac = NULL, name_key = NULL WHERE vault_id = $1", [
      Ecto.UUID.dump!(v.id)
    ])

    assert [line] = lines(uncascaded(u, v, "A", "B"))
    assert line =~ "reason=unkeyed"
  end

  test "no_op: the same path", %{user: u, vault: v} do
    assert [line] = lines(uncascaded(u, v, "A", "A"))
    assert line =~ "reason=no_op"
  end

  test "a served uncascaded move logs nothing", %{user: u, vault: v} do
    assert lines(uncascaded(u, v, "A", "B")) == []
  end
end
