defmodule Engram.NotesRmwTest do
  @moduledoc """
  `Notes.rmw_note/5` called outside a transaction (the REST append): the
  rebuild, merge and encryption hold no pool connection; only a miss or a
  lost race opens the locked transaction.
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Rmw", Ecto.UUID.generate())

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A\n"}, actor: "api")

    %{user: user, vault: vault}
  end

  test "the rebuild runs with no transaction open", %{user: user, vault: vault} do
    test = self()

    rebuild = fn current ->
      send(test, {:rebuilt_in_txn, Engram.Repo.in_transaction?()})
      current <> "more\n"
    end

    assert {{:ok, note}, _} = Notes.rmw_note(user, vault, "a.md", rebuild, actor: "api")
    assert note.content =~ "more"
    assert_received {:rebuilt_in_txn, false}
    refute_received {:rebuilt_in_txn, _}
  end

  # Outside a transaction no lock could outlive the call, so a miss must not
  # open a locked transaction just to find nothing.
  test "outside a transaction a miss takes no vault lock", %{user: user, vault: vault} do
    {{{:error, :not_found}, nil}, queries} =
      Engram.QueryRecorder.record(fn ->
        Notes.rmw_note(user, vault, "missing.md", & &1, actor: "api")
      end)

    me = self()
    refute Enum.any?(queries, &(&1.pid == me and &1.sql =~ "FOR NO KEY UPDATE"))
  end

  test "inside a caller's transaction a miss still returns holding the vault lock", ctx do
    %{user: user, vault: vault} = ctx

    assert {:ok, {{:error, :not_found}, nil}} =
             Engram.Repo.with_tenant(user.id, fn ->
               Notes.rmw_note(user, vault, "missing.md", & &1, actor: "api")
             end)
  end

  test "REST append renders after its write committed", %{user: user, vault: vault} do
    {:ok, key, _} = Engram.Accounts.create_api_key(user, "rmw")
    lift_api_rps_cap!(user)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> put_req_header("x-vault-id", vault.id)
      |> post("/api/notes/append", %{path: "a.md", text: "tail"})

    assert %{"created" => false, "note" => %{"content" => content}} = json_response(conn, 200)
    assert content =~ "tail"
  end
end
