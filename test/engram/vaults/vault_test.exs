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

    test "rejects a slug that is not URL-safe" do
      # Case is deliberately absent: `update_change` downcases before this
      # runs, so "UPPER" normalizes to a valid "upper" rather than failing.
      # That path is covered by "still downcases and trims" below.
      #
      # The shape check that replaced the reserved-word list. `slugify/1` can
      # only emit this shape; anything else reaching the changeset is a
      # caller bug (or a regression in slugify) and should not reach the DB.
      for bad <- [
            "Has Space",
            "trailing-",
            "-leading",
            "double--hyphen",
            "sl/ash",
            "dot.ted",
            "üñí"
          ] do
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, bad))
        refute cs.valid?, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "accepts every slug slugify/1 can produce, including non-ASCII names" do
      for name <- ["Café Notes", "Zürich Notes", "日本語", "Работа", "Work", "!!!"] do
        slug = Engram.Vaults.slugify(name)
        assert String.valid?(slug), "slugify(#{name}) emitted invalid UTF-8: #{inspect(slug)}"
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, slug))
        assert cs.valid?, "slugify(#{name}) -> #{inspect(slug)} was rejected by the changeset"
      end
    end

    test "still downcases and trims" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "  Work  "))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :slug) == "work"
    end
  end
end
