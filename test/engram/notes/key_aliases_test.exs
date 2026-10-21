defmodule Engram.Notes.KeyAliasesTest do
  use ExUnit.Case, async: true

  alias Engram.Crypto
  alias Engram.Indexing.PayloadV5
  alias Engram.Notes.FlatFields
  alias Engram.Notes.Frontmatter
  alias Engram.Notes.KeyAliases
  alias Engram.Notes.OkfFields
  alias Engram.Parsers.Markdown

  @fk :crypto.strong_rand_bytes(32)
  @ja "frontend/src/i18n/locale/keys/ja.json" |> File.read!() |> Jason.decode!()

  describe "canonical/1" do
    test "the English key in any casing or width" do
      assert KeyAliases.canonical("type") == "type"
      assert KeyAliases.canonical("Type") == "type"
      assert KeyAliases.canonical("ｔｙｐｅ") == "type"
      assert KeyAliases.canonical("ＤＥＳＣＲＩＰＴＩＯＮ") == "description"
    end

    test "a generated localized name" do
      assert KeyAliases.canonical("種類") == "type"
      assert KeyAliases.canonical(@ja["description"]) == "description"
      assert KeyAliases.canonical("Beschreibung") == "description"
    end

    test "a name with a space matches on its NFKC form" do
      for {norm, field} <- KeyAliases.aliases(), String.contains?(norm, " ") do
        assert KeyAliases.canonical(String.upcase(norm)) == field
      end
    end

    test "user keys, tags and OKF English aliases are not named fields" do
      assert KeyAliases.canonical("mood") == nil
      assert KeyAliases.canonical("tags") == nil
      assert KeyAliases.canonical("resource") == nil
    end

    test "a word two fields share in one locale is dropped for both" do
      # it ships `scadenza` for both expires and due.
      it = "frontend/src/i18n/locale/keys/it.json" |> File.read!() |> Jason.decode!()
      assert it["expires"] == it["due"]
      assert KeyAliases.canonical(it["due"]) == nil
      assert KeyAliases.canonical("expires") == "expires"
    end

    # One source of truth with the web app (frontmatter-keys.ts reads it too).
    test "the named fields and English names come from the shared spec" do
      spec =
        "frontend/src/i18n/frontmatter-key-fields.json"
        |> File.read!()
        |> Jason.decode!(objects: :ordered_objects)

      fields = Enum.map(spec["fields"].values, &elem(&1, 0))
      assert KeyAliases.fields() == fields
      assert KeyAliases.english() == MapSet.new(fields ++ spec["english"])
    end

    test "the table is versioned by its content" do
      assert is_integer(KeyAliases.version()) and KeyAliases.version() > 0
    end

    test "no alias points at an English key name" do
      english = ~w(type tags status author reviewed_by source project created updated reviewed
                   expires due priority description resource sources date timestamp modified
                   stale_after generated verified title aliases)

      assert Enum.filter(Map.keys(KeyAliases.aliases()), &(&1 in english)) == []
    end
  end

  describe "canonicalize/1 collisions" do
    test "an alias alone becomes the English key" do
      assert KeyAliases.canonicalize(%{"種類" => "会議", "mood" => "ok"}) ==
               %{"type" => "会議", "mood" => "ok"}
    end

    test "canonical English wins; the losing alias is kept as a user key" do
      assert KeyAliases.canonicalize(%{"type" => "a", "種類" => "b"}) ==
               %{"type" => "a", "種類" => "b"}
    end

    test "another spelling of the English key beats an alias" do
      assert KeyAliases.canonicalize(%{"ｔｙｐｅ" => "a", "種類" => "b"}) ==
               %{"type" => "a", "種類" => "b"}
    end

    test "between two aliases the first locale in order wins" do
      # cs comes before ja in Engram.I18n.locales/0.
      assert KeyAliases.canonicalize(%{"種類" => "ja", "typ" => "cs"}) ==
               %{"type" => "cs", "種類" => "ja"}
    end

    test "the losing alias reaches the user-key long tail" do
      flat = FlatFields.extract("---\nstatus: a\n状態: b\n---\n", @fk)
      assert flat.status == "a"
      assert [%{k: k}] = flat.attrs
      assert flat.names[k] == "状態"
    end
  end

  # Requirement: a note written with localized keys indexes exactly like the
  # English one: flat fields, payload keys and the chunk-0 lead line.
  test "localized type and description index like the English keys" do
    english = "---\ntype: 会議\ndescription: 週次の定例\nstatus: draft\n---\n# 会議\n本文\n"

    localized =
      "---\n種類: 会議\n#{@ja["description"]}: 週次の定例\n#{@ja["status"]}: draft\n---\n# 会議\n本文\n"

    assert index(localized) == index(english)
    assert {"会議: 週次の定例", _, _} = index(english)
  end

  defp index(content) do
    {block, _} = Frontmatter.split(content)
    okf = OkfFields.from_parse(Frontmatter.parse(block))
    flat = FlatFields.extract(content, @fk)

    note = %{
      user_id: "00000000-0000-0000-0000-000000000001",
      vault_id: "00000000-0000-0000-0000-000000000002",
      path_hmac: nil,
      folder_hmac: nil,
      type_hmac: Crypto.hmac_field(@fk, OkfFields.normalize_type(okf.type)),
      tags_hmac: [],
      mtime: 1,
      ctime: 1
    }

    [chunk0 | _] = Markdown.parse(content, "n.md")

    {Markdown.lead(OkfFields.values(Frontmatter.parse(block))), PayloadV5.build(note, flat),
     chunk0.embed_text}
  end
end
