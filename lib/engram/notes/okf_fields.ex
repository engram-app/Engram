defmodule Engram.Notes.OkfFields do
  @moduledoc """
  Extraction of the OKF standard frontmatter fields (plus the `created`
  extension) from note content. v0.2 dates a note by `generated.at`; the
  deprecated v0.1 `timestamp` (and its `modified`/`updated` aliases) is the
  fallback. Pure functions; extraction never errors, so a
  malformed note still syncs (all fields degrade to nil).

  Crypto line (spec-locked): only the two dates are stored plaintext; `type`
  is encrypted with an HMAC blind index; `description`/`resource` are
  encrypted display-only.
  """

  alias Engram.Notes.Frontmatter

  # Key paths into the decoded frontmatter, first valid wins. v0.2
  # (amended 2026-08-21) requires `generated.at` to be a full datetime with
  # an offset, so a date-only one reads as absent rather than as midnight
  # UTC shadowing a valid `timestamp`. The older keys keep their leniency.
  @timestamp_aliases [
    {~w(generated at), :strict},
    {~w(timestamp), :lenient},
    {~w(modified), :lenient},
    {~w(updated), :lenient}
  ]
  @created_aliases [{~w(created), :lenient}, {~w(date), :lenient}]

  @type t :: %{
          type: String.t() | nil,
          description: String.t() | nil,
          resource: String.t() | nil,
          fm_timestamp: DateTime.t() | nil,
          fm_created: DateTime.t() | nil
        }

  @empty %{type: nil, description: nil, resource: nil, fm_timestamp: nil, fm_created: nil}

  @doc """
  OKF fields from an already-computed `Frontmatter.parse/1` result, so a
  caller that also needs the parse for something else (parse_status) parses
  the block once. `nil` (no frontmatter) and `:error` give all-nil.
  """
  @spec from_parse(Frontmatter.parse_result() | nil) :: t()
  def from_parse({:ok, _order, values, _degraded}) do
    decoded = decode_values(values)

    %{
      type: string_field(decoded["type"]),
      description: string_field(decoded["description"]),
      resource: string_field(decoded["resource"]),
      fm_timestamp: first_date(decoded, @timestamp_aliases),
      fm_created: first_date(decoded, @created_aliases)
    }
  end

  def from_parse(_none_or_error), do: @empty

  @doc """
  Canonical form for the `type_hmac` blind index. Write path and search
  filter translation MUST both use this so `Playbook` and `playbook`
  land in the same filter bucket.
  """
  @spec normalize_type(String.t()) :: String.t()
  def normalize_type(type) when is_binary(type) do
    type |> String.normalize(:nfkc) |> String.downcase()
  end

  @doc """
  The decoded top-level frontmatter values of a `Frontmatter.parse/1` result
  (`%{}` for no frontmatter or a parse error). Shared with `FlatFields`, so
  the v5 fields read the same terms as the OKF ones.
  """
  @spec values(Frontmatter.parse_result() | nil) :: %{String.t() => term()}
  def values({:ok, _order, values, _degraded}), do: decode_values(values)
  def values(_none_or_error), do: %{}

  @doc """
  The first alias path holding a valid date, as a UTC `DateTime`. `:strict`
  needs a full datetime with an offset (the nested OKF aliases); `:lenient`
  also takes a bare date as midnight UTC.
  """
  @spec first_date(map(), [{[String.t()], :strict | :lenient}]) :: DateTime.t() | nil
  def first_date(decoded, aliases) do
    Enum.find_value(aliases, fn {path, mode} -> path |> dig(decoded) |> parse_datetime(mode) end)
  end

  @doc "One date value under `mode` (see `first_date/2`)."
  @spec parse_date_value(term(), :strict | :lenient) :: DateTime.t() | nil
  def parse_date_value(value, mode), do: parse_datetime(value, mode)

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

  # A non-map at an intermediate key (`generated: "text"`) reads as absent.
  defp dig([], value), do: value
  defp dig([key | rest], %{} = map), do: dig(rest, Map.get(map, key))
  defp dig(_path, _not_a_map), do: nil

  defp parse_datetime(v, mode) when is_binary(v) do
    case {DateTime.from_iso8601(v), mode} do
      {{:ok, dt, _offset}, _mode} -> DateTime.truncate(dt, :second)
      {{:error, _}, :strict} -> nil
      {{:error, _}, :lenient} -> parse_date(v)
    end
  end

  defp parse_datetime(_v, _mode), do: nil

  defp parse_date(v) do
    case Date.from_iso8601(v) do
      {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
      {:error, _} -> nil
    end
  end
end
