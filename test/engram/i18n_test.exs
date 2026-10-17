defmodule Engram.I18nTest do
  use ExUnit.Case, async: true

  alias Engram.I18n

  describe "locale_for/1" do
    test "maps a stored BCP 47 tag onto a supported locale" do
      for {tag, want} <- [
            {"de", "de"},
            {"de-AT", "de"},
            {"pt-BR", "pt-BR"},
            {"pt-PT", "pt-BR"},
            {"zh-Hant-TW", "zh-TW"},
            {"zh-HK", "zh-TW"},
            {"zh", "zh-CN"},
            {"ZH-cn", "zh-CN"},
            {"es-419", "es"},
            {"tr-TR", "tr"},
            {"pl", "pl"},
            {"id-ID", "id"}
          ],
          do: assert(I18n.locale_for(%{locale: tag}) == want, tag)
    end

    test "falls back to English for nil, unknown or missing" do
      assert I18n.locale_for(%{locale: nil}) == "en"
      assert I18n.locale_for(%{locale: "xx-YY"}) == "en"
      assert I18n.locale_for(%{}) == "en"
    end
  end

  describe "t/3" do
    test "English is the key itself, with placeholders filled" do
      assert I18n.t("en", "Hi {name},", name: "Ada") == "Hi Ada,"
    end

    test "a missing translation falls back to English" do
      assert I18n.t("de", "No such key {x}", x: "1") == "No such key 1"
    end

    test "uses the catalog when it has the key" do
      assert I18n.t("de", "__test__", [], %{"de" => %{"__test__" => "Prüfung"}}) == "Prüfung"
    end
  end

  test "dates read naturally in English and as ISO elsewhere" do
    assert I18n.date("en", ~D[2026-11-11]) == "November 11, 2026"
    assert I18n.date("ja", ~D[2026-11-11]) == "2026-11-11"
  end
end
