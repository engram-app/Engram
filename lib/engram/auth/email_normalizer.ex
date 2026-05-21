defmodule Engram.Auth.EmailNormalizer do
  @moduledoc """
  Normalize email addresses so provider-specific aliasing rules (Gmail dotted
  aliases, plus-addressing) collapse to a single canonical form. Used at
  signup to prevent multi-account farming (pricing-v2 §A).
  """

  # Each entry: domain => {canonical_domain, strip_dots?, strip_plus?}
  @providers %{
    "gmail.com" => {"gmail.com", true, true},
    "googlemail.com" => {"gmail.com", true, true},
    "fastmail.com" => {"fastmail.com", false, true},
    "fastmail.fm" => {"fastmail.fm", false, true},
    "protonmail.com" => {"protonmail.com", false, true},
    "proton.me" => {"proton.me", false, true},
    "pm.me" => {"pm.me", false, true},
    "icloud.com" => {"icloud.com", false, true},
    "me.com" => {"me.com", false, true},
    "mac.com" => {"mac.com", false, true}
  }

  @spec normalize(String.t()) :: String.t()
  def normalize(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    case String.split(email, "@", parts: 2) do
      [local, domain] -> apply_rules(local, domain)
      _ -> email
    end
  end

  @spec same_identity?(String.t(), String.t()) :: boolean()
  def same_identity?(a, b) when is_binary(a) and is_binary(b) do
    normalize(a) == normalize(b)
  end

  defp apply_rules(local, domain) do
    case Map.fetch(@providers, domain) do
      {:ok, {canonical_domain, strip_dots?, strip_plus?}} ->
        local
        |> maybe_strip_plus(strip_plus?)
        |> maybe_strip_dots(strip_dots?)
        |> Kernel.<>("@" <> canonical_domain)

      :error ->
        local <> "@" <> domain
    end
  end

  defp maybe_strip_plus(local, true), do: local |> String.split("+", parts: 2) |> hd()
  defp maybe_strip_plus(local, false), do: local

  defp maybe_strip_dots(local, true), do: String.replace(local, ".", "")
  defp maybe_strip_dots(local, false), do: local
end
