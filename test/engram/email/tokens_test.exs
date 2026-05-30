defmodule Engram.Email.TokensTest do
  use ExUnit.Case, async: true

  alias Engram.Email.Tokens

  @hex_regex ~r/^#[0-9a-f]{6}$/

  describe "all token functions return lowercase 6-char hex" do
    for fun <- [
          :brand_purple,
          :brand_purple_fg,
          :text_primary,
          :text_muted,
          :surface_card,
          :surface_page
        ] do
      test "#{fun}/0 returns valid hex" do
        value = apply(Tokens, unquote(fun), [])

        assert value =~ @hex_regex,
               "expected lowercase #rrggbb hex from Tokens.#{unquote(fun)}, got: #{inspect(value)}"
      end
    end

    test "brand_purple is not the legacy hardcoded #5b5bd6" do
      refute Tokens.brand_purple() == "#5b5bd6",
             "Tokens.brand_purple/0 must be the regenerated palette value, not the pre-sync hardcoded purple"
    end
  end
end
