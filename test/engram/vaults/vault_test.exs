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

    test "rejects a slug that the metrics forward 401s on" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "metrics"))
      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug
    end

    test "accepts an ordinary slug" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "work"))
      assert cs.valid?
    end

    test "rejection is case-insensitive" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "Settings"))
      refute cs.valid?
    end

    test "rejection trims whitespace, matching the TS mirror's .trim()" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "  settings  "))
      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug
    end

    # Pins the exact 18-entry list. Written as a literal, not derived from
    # @reserved_slugs, so a deleted entry breaks this test instead of
    # silently passing. Mirrored 1:1 in reserved-slugs.test.ts, a human
    # dropping an entry from either list must edit both and notice.
    test "the reserved list is exactly this set" do
      assert Vault.reserved_slugs() == ~w(
               sign-in sign-up waitlist link oauth onboard reset-password
               note search billing settings api webhooks .well-known
               assets email socket metrics
             )
    end
  end
end
