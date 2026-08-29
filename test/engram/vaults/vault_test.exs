defmodule Engram.Vaults.VaultTest do
  use Engram.DataCase, async: true

  alias Engram.Vaults.Vault

  @valid %{
    user_id: Ecto.UUID.generate(),
    name_ciphertext: <<1>>,
    name_nonce: <<2>>,
    name_hmac: <<3>>
  }

  describe "slugs" do
    # Vault routes live under `/v/:slug`, so no slug can collide with a
    # top-level app route, a Plug.Static mount, or a Phoenix scope. The
    # former @reserved_slugs list (and its TS mirror in
    # frontend/src/api/reserved-slugs.ts) existed only because `/:slug` sat
    # at the root; both are deleted. These names are now ordinary slugs.
    test "accepts slugs that used to be reserved" do
      for slug <- ~w(
            sign-in sign-up waitlist link oauth onboard reset-password
            note search billing settings api webhooks assets email socket metrics
          ) do
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, slug))
        assert cs.valid?, "expected #{slug} to be accepted, got #{inspect(errors_on(cs))}"
      end
    end

    test "accepts an ordinary slug" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "work"))
      assert cs.valid?
    end

    test "still downcases and trims" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "  Work  "))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :slug) == "work"
    end
  end
end
