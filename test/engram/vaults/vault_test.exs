defmodule Engram.Vaults.VaultTest do
  use Engram.DataCase, async: true

  alias Engram.Vaults.Vault

  @valid %{
    user_id: Ecto.UUID.generate(),
    name_ciphertext: <<1>>,
    name_nonce: <<2>>,
    name_hmac: <<3>>
  }

  describe "reserved slugs" do
    test "rejects a slug that would be shadowed by a static SPA route" do
      for slug <- ~w(settings link oauth onboard note api sign-in) do
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, slug))
        refute cs.valid?, "expected #{slug} to be rejected"
        assert "is reserved" in errors_on(cs).slug
      end
    end

    test "rejects a slug that Task 7's backend deny-list 404s on" do
      for slug <- ~w(webhooks assets email socket) do
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, slug))
        refute cs.valid?, "expected #{slug} to be rejected"
        assert "is reserved" in errors_on(cs).slug
      end
    end

    test "accepts an ordinary slug" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "work"))
      assert cs.valid?
    end

    test "rejection is case-insensitive" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "Settings"))
      refute cs.valid?
    end
  end
end
