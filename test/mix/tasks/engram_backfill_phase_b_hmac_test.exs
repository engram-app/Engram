defmodule Mix.Tasks.Engram.BackfillPhaseBHmacTest do
  use Engram.DataCase, async: false

  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Mix.Tasks.Engram.BackfillPhaseBHmac

  describe "gather_pairs/0" do
    test "includes vault-only pair when vault has name_hmac=nil and no notes" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Verify factory leaves name_hmac nil
      assert is_nil(vault.name_hmac)

      pairs = BackfillPhaseBHmac.gather_pairs()

      assert {user.id, vault.id} in pairs
    end

    test "includes pair from note with path_hmac=nil" do
      user = insert(:user)
      vault = insert(:vault, user: user, name_hmac: <<1::256>>)

      Repo.with_tenant(user.id, fn ->
        %Note{}
        |> Note.changeset(%{
          path: "docs/legacy.md",
          folder: "docs",
          content: "x",
          tags: [],
          user_id: user.id,
          vault_id: vault.id
        })
        |> Repo.insert!()
      end)

      pairs = BackfillPhaseBHmac.gather_pairs()

      assert {user.id, vault.id} in pairs
    end

    test "includes pair from attachment with path_hmac=nil and no notes needing backfill" do
      user = insert(:user)
      vault = insert(:vault, user: user, name_hmac: <<1::256>>)

      Repo.with_tenant(user.id, fn ->
        %Attachment{}
        |> Ecto.Changeset.change(%{
          path: "files/image.png",
          content_hash: "abc123",
          mime_type: "image/png",
          size_bytes: 4,
          content_nonce: <<0::96>>,
          encryption_version: 1,
          user_id: user.id,
          vault_id: vault.id
        })
        |> Repo.insert!()
      end)

      pairs = BackfillPhaseBHmac.gather_pairs()

      assert {user.id, vault.id} in pairs
    end

    test "excludes vault when all three sources are already populated" do
      user = insert(:user)
      vault = insert(:vault, user: user, name_hmac: <<1::256>>)

      # Note with path_hmac set
      Repo.with_tenant(user.id, fn ->
        %Note{}
        |> Note.changeset(%{
          path: "done/note.md",
          folder: "done",
          content: "x",
          tags: [],
          user_id: user.id,
          vault_id: vault.id,
          path_hmac: <<2::256>>,
          path_ciphertext: <<3::128>>,
          path_nonce: <<4::96>>
        })
        |> Repo.insert!()
      end)

      pairs = BackfillPhaseBHmac.gather_pairs()

      refute {user.id, vault.id} in pairs
    end

    test "deduplicates pairs appearing in multiple sources" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Both note and vault contribute the same pair
      assert is_nil(vault.name_hmac)

      Repo.with_tenant(user.id, fn ->
        %Note{}
        |> Note.changeset(%{
          path: "dup/note.md",
          folder: "dup",
          content: "x",
          tags: [],
          user_id: user.id,
          vault_id: vault.id
        })
        |> Repo.insert!()
      end)

      pairs = BackfillPhaseBHmac.gather_pairs()

      count = Enum.count(pairs, fn p -> p == {user.id, vault.id} end)
      assert count == 1
    end
  end
end
