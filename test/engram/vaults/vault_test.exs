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
      # Each entry is a shape that reached the changeset and was WRONG at some
      # point: the accented ones emitted invalid UTF-8, the stroke letters were
      # amputated to "rsted"/"odz"/"or", the underscore ones collapsed to
      # "myvault", and the long one exceeded validate_length.
      for name <- [
            "Café Notes",
            "Zürich Notes",
            "Ørsted Notes",
            "Łódź Notes",
            "Æther",
            "Þor",
            "Đà Nẵng",
            "ﬁle notes",
            "日本語",
            "Работа",
            "my_vault",
            "work-log_v2",
            "Work",
            "!!!",
            String.duplicate("a", 130),
            String.duplicate("long name ", 40)
          ] do
        slug = Engram.Vaults.slugify(name)
        assert String.valid?(slug), "slugify(#{name}) emitted invalid UTF-8: #{inspect(slug)}"
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, slug))
        assert cs.valid?, "slugify(#{name}) -> #{inspect(slug)} was rejected by the changeset"
      end
    end

    test "underscores become hyphens, not nothing" do
      # Regression: filtering to [a-z0-9-] BEFORE converting [\s_] deleted the
      # underscore instead of hyphenating it, so a vault at /v/work-notes moved
      # to /v/worknotes the first time its name was edited.
      assert Engram.Vaults.slugify("my_vault") == "my-vault"
      assert Engram.Vaults.slugify("work-log_v2") == "work-log-v2"
    end

    test "stroke letters and ligatures survive instead of being amputated" do
      # NFD alone leaves these intact (they are not base + combining mark), so
      # the ASCII filter removed them outright and Norwegian/Polish/Icelandic
      # users lost the first letter of their vault name.
      assert Engram.Vaults.slugify("Ørsted") == "orsted"
      assert Engram.Vaults.slugify("Łódź") == "lodz"
      assert Engram.Vaults.slugify("Þor") == "thor"
      assert Engram.Vaults.slugify("Æther") == "aether"
      assert Engram.Vaults.slugify("ﬁle") == "file"
    end

    test "slugify leaves headroom for the unique_slug dedup suffix" do
      # A maximal base slug plus "-1000" must still pass validate_length,
      # otherwise a collision produces a 422 the caller cannot anticipate.
      base = Engram.Vaults.slugify(String.duplicate("a", 500))
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "#{base}-1000"))
      assert cs.valid?, "base+suffix was rejected: #{inspect(errors_on(cs))}"
    end

    test "a pre-existing row whose slug the format rejects still accepts unrelated updates" do
      # `validate_format` is newer than the rows it will meet: slugs written
      # before it exist in shapes it rejects (the old byte-wise slugify
      # produced some). Ecto validates CHANGES, not persisted values, so
      # editing a description on such a row must not start failing. Asserted
      # rather than assumed -- it is the one way this validation could break
      # a write path that used to work.
      legacy = %Vault{slug: "Legacy_BAD--slug-", user_id: Ecto.UUID.generate()}

      cs =
        Vault.changeset(legacy, %{
          description: "new description",
          name_ciphertext: <<1>>,
          name_nonce: <<2>>,
          name_hmac: <<3>>
        })

      assert cs.valid?,
             "a legacy slug must not block unrelated updates: #{inspect(errors_on(cs))}"
    end

    test "still downcases and trims" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "  Work  "))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :slug) == "work"
    end
  end
end
