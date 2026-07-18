defmodule Engram.Notes.OkfFields do
  @moduledoc """
  Extraction of the OKF v0.1 standard frontmatter fields (plus the `created`
  extension) from note content. Pure functions; extraction never errors, so a
  malformed note still syncs (all fields degrade to nil).

  Crypto line (spec-locked): only the two dates are stored plaintext; `type`
  is encrypted with an HMAC blind index; `description`/`resource` are
  encrypted display-only.
  """

  alias Engram.Notes.Frontmatter

  @timestamp_aliases ~w(timestamp modified updated)
  @created_aliases ~w(created date)

  @type t :: %{
          type: String.t() | nil,
          description: String.t() | nil,
          resource: String.t() | nil,
          fm_timestamp: DateTime.t() | nil,
          fm_created: DateTime.t() | nil
        }

  @empty %{type: nil, description: nil, resource: nil, fm_timestamp: nil, fm_created: nil}

  @spec extract(String.t()) :: t()
  def extract(content) when is_binary(content) do
    with {block, _body} when is_binary(block) <- Frontmatter.split(content),
         {:ok, _order, values, _degraded} <- Frontmatter.parse(block) do
      decoded = decode_values(values)

      %{
        type: string_field(decoded["type"]),
        description: string_field(decoded["description"]),
        resource: string_field(decoded["resource"]),
        fm_timestamp: first_date(decoded, @timestamp_aliases),
        fm_created: first_date(decoded, @created_aliases)
      }
    else
      _ -> @empty
    end
  end

  @doc """
  Canonical form for the `type_hmac` blind index. Write path and search
  filter translation MUST both use this so `Playbook` and `playbook`
  land in the same filter bucket.
  """
  @spec normalize_type(String.t()) :: String.t()
  def normalize_type(type) when is_binary(type) do
    type |> String.normalize(:nfkc) |> String.downcase()
  end

  # Frontmatter.parse values are JSON-encoded strings; decode back to terms.
  defp decode_values(values) do
    Map.new(values, fn {k, json} ->
      case Jason.decode(json) do
        {:ok, decoded} -> {k, decoded}
        {:error, _} -> {k, nil}
      end
    end)
  end

  defp string_field(v) when is_binary(v) and v != "", do: v
  defp string_field(_), do: nil

  defp first_date(decoded, aliases) do
    Enum.find_value(aliases, fn key -> parse_datetime(decoded[key]) end)
  end

  defp parse_datetime(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} ->
        DateTime.truncate(dt, :second)

      {:error, _} ->
        case Date.from_iso8601(v) do
          {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
          {:error, _} -> nil
        end
    end
  end

  defp parse_datetime(_), do: nil
end
