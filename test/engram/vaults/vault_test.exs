defmodule Engram.Vaults.VaultTest do
  use Engram.DataCase, async: true

  alias Engram.Vaults
  alias Engram.Vaults.Vault

  @valid %{
    user_id: Ecto.UUID.generate(),
    slug_hmac: <<4>>,
    name_ciphertext: <<1>>,
    name_nonce: <<2>>,
    name_hmac: <<3>>
  }

  # Exactly the codomain of `Vaults.slugify/1`: alphanumeric groups joined by
  # single hyphens. The slug is derived from the name on read and never
  # stored, so this shape is the whole "a slug is safe in a URL" guarantee.
  @slug_shape ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  describe "changeset" do
    test "requires slug_hmac on insert" do
      cs = Vault.changeset(%Vault{}, Map.delete(@valid, :slug_hmac))
      assert %{slug_hmac: ["can't be blank"]} = errors_on(cs)
    end

    test "does not require slug_hmac or slug on update of an existing row" do
      # A row the reconciler has not reached must still delete, restore and
      # change default.
      existing =
        Ecto.put_meta(
          %Vault{
            user_id: Ecto.UUID.generate(),
            name_ciphertext: <<1>>,
            name_nonce: <<2>>,
            name_hmac: <<3>>
          },
          state: :loaded
        )

      cs = Vault.changeset(existing, %{is_default: true})

      assert cs.valid?, inspect(errors_on(cs))
    end

    test "a legacy row with a malformed stored slug still accepts unrelated updates" do
      legacy = %Vault{slug: "Legacy_BAD--slug-", slug_hmac: <<9>>, user_id: Ecto.UUID.generate()}

      cs = Vault.changeset(legacy, %{name_ciphertext: <<1>>, name_nonce: <<2>>, name_hmac: <<3>>})

      assert cs.valid?,
             "a legacy slug must not block unrelated updates: #{inspect(errors_on(cs))}"
    end
  end

  describe "slugify/1 contract" do
    test "is URL-safe, valid UTF-8 and bounded for every historically broken name" do
      # Each entry is a shape slugify got WRONG at some point: the accented
      # ones emitted invalid UTF-8, the stroke letters were amputated to
      # "rsted"/"odz"/"or", the underscore ones collapsed to "myvault", and
      # the long ones were unbounded.
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
        slug = Vaults.slugify(name)
        assert String.valid?(slug), "slugify(#{name}) emitted invalid UTF-8: #{inspect(slug)}"
        assert slug =~ @slug_shape, "slugify(#{name}) -> #{inspect(slug)} is not URL-safe"
        assert String.length(slug) <= 100, "slugify(#{name}) is unbounded"
      end
    end

    test "the id-suffixed form keeps the same shape" do
      vault = %Vault{id: Ecto.UUID.generate(), slug_suffixed: true}
      slug = Vaults.derive_slug(String.duplicate("a", 500), vault)

      assert slug =~ @slug_shape
      assert String.length(slug) <= 107
    end

    test "former reserved words are ordinary slugs" do
      # Vault routes live under `/v/:slug`, so no slug can collide with a
      # top-level app route; the old reserved list is gone.
      for word <- ~w(sign-in sign-up waitlist oauth onboard settings api webhooks) do
        assert Vaults.slugify(word) == word
      end
    end

    test "underscores become hyphens, not nothing" do
      # Regression: filtering to [a-z0-9-] BEFORE converting [\s_] deleted the
      # underscore instead of hyphenating it, so a vault at /v/work-notes moved
      # to /v/worknotes the first time its name was edited.
      assert Vaults.slugify("my_vault") == "my-vault"
      assert Vaults.slugify("work-log_v2") == "work-log-v2"
    end

    test "stroke letters and ligatures survive instead of being amputated" do
      # NFD alone leaves these intact (they are not base + combining mark), so
      # the ASCII filter removed them outright and Norwegian/Polish/Icelandic
      # users lost the first letter of their vault name.
      assert Vaults.slugify("Ørsted") == "orsted"
      assert Vaults.slugify("Łódź") == "lodz"
      assert Vaults.slugify("Þor") == "thor"
      assert Vaults.slugify("Æther") == "aether"
      assert Vaults.slugify("ﬁle") == "file"
    end
  end
end
