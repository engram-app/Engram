defmodule Engram.DataMigrations.AttachmentNameKeyTest do
  # S6 step 6 (Engram#2523): the `attachment_name_key` ledger keys the rows
  # the `attachments_set_name_key` trigger never saw, and the manifest's
  # attachment overlay (`Location.listing/3`). The fleet maintenance-pool
  # path of the same pass runs in `MaintenancePoolRegistryTest`, which takes
  # every registered migration.
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Notes, Repo, ServiceConfig}
  alias Engram.Attachments.Location
  alias Engram.DataMigrations.AttachmentNameKey

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "A/x.png",
        "content_base64" => Base.encode64("bytes")
      })

    %{user: user, vault: vault, att: att}
  end

  defp key(id),
    do: Repo.query!("SELECT name_key FROM attachments WHERE id = $1", [Ecto.UUID.dump!(id)]).rows

  test "keys a row the trigger never saw, and off it runs no pass", %{att: att} do
    raw = Ecto.UUID.dump!(att.id)
    Repo.query!("ALTER TABLE attachments DISABLE TRIGGER attachments_set_name_key")

    try do
      Repo.query!("UPDATE attachments SET name_key = NULL WHERE id = $1", [raw])
    after
      Repo.query!("ALTER TABLE attachments ENABLE TRIGGER attachments_set_name_key")
    end

    assert [[nil]] = key(att.id)

    ServiceConfig.put_override(:attachment_name_key, false)
    refute AttachmentNameKey.enabled?()
    ServiceConfig.put_override(:attachment_name_key, true)

    AttachmentNameKey.run_pass()
    assert [[k]] = key(att.id)
    assert is_binary(k)
  end

  test "a stale folder reference clears the key", %{att: att} do
    # Keyed by the trigger at the write, or "cleared" below proves nothing.
    assert [[k]] = key(att.id)
    assert is_binary(k)

    Repo.query!("UPDATE attachments SET folder_ref_stamp = NULL WHERE id = $1", [
      Ecto.UUID.dump!(att.id)
    ])

    assert [[nil]] = key(att.id)
  end

  test "the manifest overlay serves the shown path and the move's seq", %{user: u, vault: v} do
    assert {%{}, %{}} == Location.listing(u, v.id)

    {:ok, {:ok, 1}} =
      Repo.with_tenant(u.id, fn -> Notes.rename_folder_uncascaded(u, v, "A", "B") end)

    {paths, seqs} = Location.listing(u, v.id)
    assert Map.values(paths) == ["B/x.png"]
    assert [seq] = Map.values(seqs)
    assert seq > 0
  end
end
