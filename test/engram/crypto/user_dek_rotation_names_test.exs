defmodule Engram.Crypto.UserDekRotationNamesTest do
  # A DEK rotation re-encrypts and re-keys the row names S2 added (O(1)
  # folder rename plan): `notes` and `attachments` name envelopes, `name_hmac`
  # and `name_ci_hmac` under the new filter key, stamped for the rewrapped
  # path nonce; `folders.name_ci_hmac` under the new filter key, stamped for
  # the rewrapped name nonce. A name left under the old DEK would still carry
  # a matching stamp after a path rewrap that wrote no name, so the backfill
  # would never heal it: this is the only proof.
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, UserDekRotation}
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Notes.Name
  alias Engram.Repo

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "NameRotation", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp row(table, id) do
    %{rows: [[ct, nonce, h, ci, stamp, path_nonce]]} =
      Repo.query!(
        "SELECT name_ciphertext, name_nonce, name_hmac, name_ci_hmac, name_stamp, path_nonce " <>
          "FROM #{table} WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    %{ct: ct, nonce: nonce, hmac: h, ci: ci, stamp: stamp, path_nonce: path_nonce}
  end

  defp folder_row(user_id, name, dek) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, name_ciphertext, name_nonce, name_ci_hmac, name_stamp FROM folders " <>
          "WHERE user_id = $1",
        [Ecto.UUID.dump!(user_id)]
      )

    Enum.find_value(rows, fn [id, ct, nonce, ci, stamp] ->
      id = Ecto.UUID.load!(id)

      case Envelope.decrypt(ct, nonce, dek, Crypto.aad_for_row(:folders, :name, id)) do
        {:ok, ^name} -> %{ci: ci, stamp: stamp, nonce: nonce}
        _ -> nil
      end
    end)
  end

  test "rotation rewraps note, attachment and folder names under the new key", %{
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Docs/Report.md", "content" => "# T\n\nb"},
        actor: "api"
      )

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        path: "Docs/Pic.PNG",
        content: <<137, 80, 78, 71, 1>>
      })

    {:ok, old_dek} = Crypto.get_dek(user)
    before = %{note: row("notes", note.id), att: row("attachments", att.id)}

    assert :ok = UserDekRotation.rotate_user(user.id)

    user = Engram.Accounts.get_user_uncached(user.id)
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    refute dek == old_dek

    for {table, id, name, key} <- [
          {"notes", note.id, "Report.md", :note},
          {"attachments", att.id, "Pic.PNG", :att}
        ] do
      r = row(table, id)
      refute r.ct == before[key].ct

      assert {:ok, ^name} =
               Name.decrypt(String.to_existing_atom(table), dek, id, r.ct, r.nonce)

      assert :error =
               Name.decrypt(String.to_existing_atom(table), old_dek, id, r.ct, r.nonce)

      assert r.hmac == Name.hmac(fk, name)
      assert r.ci == Name.ci_hmac(fk, name)
      assert r.stamp == Name.stamp(r.path_nonce)
    end

    docs = folder_row(user.id, "Docs", dek)
    assert docs, "the folder name did not rewrap under the new DEK"
    assert docs.ci == Folder.name_ci_hmac(fk, "Docs")
    assert docs.stamp == Name.stamp(docs.nonce)
  end
end
