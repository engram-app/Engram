defmodule Engram.I18n do
  @moduledoc """
  Backend text in the user's language: today, email (`Engram.Mailer`).

  The English string is the key, exactly as in the web app: `t(locale,
  "Hi {name},", name: name)`. Catalogs live in `priv/i18n/email/<locale>.json`
  and are written by translategemma (`bun run i18n:translate` in `frontend/`,
  which scans `t(locale, "...")` calls here and in the mailer, plus the
  seeder's changelogs). A missing key falls back to English, so a new string
  ships in English until the nightly bot translates it.

  Returns plain text. Callers escape it for HTML.
  """

  # Mirrors frontend/src/i18n/locales.ts (`LOCALES`, `matchLocale`).
  @locales ~w(en cs de es fr id it ja ko ms pl pt-BR ru tr uk vi zh-CN zh-TW)
  @by_lower Map.new(@locales, &{String.downcase(&1), &1})

  @dir Path.expand("../../priv/i18n/email", __DIR__)
  @catalogs (for code <- @locales -- ["en"], into: %{} do
               path = Path.join(@dir, "#{code}.json")
               @external_resource path
               {code,
                if(File.exists?(path), do: path |> File.read!() |> Jason.decode!(), else: %{})}
             end)

  @type locale :: String.t()

  @doc "The supported locale for `user.locale` (a BCP 47 tag), or \"en\"."
  @spec locale_for(map()) :: locale()
  def locale_for(%{locale: tag}) when is_binary(tag), do: match(String.downcase(tag)) || "en"
  def locale_for(_user), do: "en"

  defp match(tag) do
    base = tag |> String.split("-") |> hd()

    cond do
      Map.has_key?(@by_lower, tag) -> @by_lower[tag]
      Regex.match?(~r/^zh-(tw|hk|mo|hant)/, tag) -> "zh-TW"
      base == "zh" -> "zh-CN"
      base == "pt" -> "pt-BR"
      # Slovak readers get Czech, the closest language we ship.
      base == "sk" -> "cs"
      true -> @by_lower[base]
    end
  end

  @doc "`key` in `locale` with `{name}` placeholders filled from `vars`."
  @spec t(locale(), String.t(), keyword(), map()) :: String.t()
  def t(locale, key, vars \\ [], catalogs \\ @catalogs) do
    text =
      case catalogs do
        %{^locale => %{^key => text}} when is_binary(text) -> text
        _ -> key
      end

    Enum.reduce(vars, text, fn {name, value}, acc ->
      String.replace(acc, "{#{name}}", to_string(value))
    end)
  end

  # ponytail: ISO outside English rather than a CLDR dependency for month
  # names and date order. Add ex_cldr if a localized long date is wanted.
  @doc "A date as \"November 11, 2026\" in English, ISO 8601 otherwise."
  @spec date(locale(), Date.t()) :: String.t()
  def date("en", date), do: Calendar.strftime(date, "%B %-d, %Y")
  def date(_locale, date), do: Date.to_iso8601(date)
end
