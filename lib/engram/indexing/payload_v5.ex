defmodule Engram.Indexing.PayloadV5 do
  @moduledoc """
  The v5 note-level Qdrant payload (spec 3.3b): filter fields and ids only,
  under the short keys of `Engram.Vector.PayloadKeys`. No text, title,
  heading, nonce, `aad_version` or `note_id` (Postgres maps a point to its
  note through `chunks.qdrant_point_id`).

  An absent field is omitted, never `nil` or `[]`. Defaults are omitted too:
  `status: stable` and a date source of frontmatter store no key, so a filter
  for a default matches a missing key (`is_empty` / `must_not has`).

  Dates: `up`, `cr`, `rd` are unix seconds; the date-only `ex` and `du` are
  day numbers (days since 1970-01-01). When the frontmatter has no
  `updated`/`created`, `up` falls back to the file mtime (flag `us` = 1,
  file) or the row's `updated_at` (2, server), and `cr` to the file ctime
  (`cs` = 1) or `created_at` (2). The flags are small integers rather than
  strings to keep a point small.
  """

  alias Engram.Notes.FlatFields
  alias Engram.Notes.OkfFields
  alias Engram.Vector.FilterId

  import Engram.Vector.PayloadKeys, only: [short: 1]

  @file_src 1
  @server_src 2
  @day 86_400

  @spec build(map(), FlatFields.t()) :: %{String.t() => term()}
  def build(note, flat) do
    {up, us} = updated(note, flat.fm_updated)
    {cr, cs} = created(note, flat.fm_created)

    [
      user_id: FilterId.uuid(to_string(note.user_id)),
      vault_id: FilterId.uuid(to_string(note.vault_id)),
      path_id: FilterId.from_hmac(note.path_hmac),
      folder_id: FilterId.from_hmac(note.folder_hmac),
      type_id: FilterId.from_hmac(note.type_hmac),
      tags_id: Enum.map(note.tags_hmac || [], &FilterId.from_hmac/1),
      status_id: unless(stable?(flat.status), do: FilterId.from_hmac(flat.status_hmac)),
      author_id: FilterId.from_hmac(flat.author_hmac),
      rev_by_id: FilterId.from_hmac(flat.rev_by_hmac),
      src_id: Enum.map(flat.src_hmac, &FilterId.from_hmac/1),
      proj_id: FilterId.from_hmac(flat.proj_hmac),
      fm_timestamp: up,
      fm_timestamp_src: us,
      fm_created: cr,
      fm_created_src: cs,
      fm_reviewed: flat.fm_reviewed,
      fm_expires: day(flat.fm_expires),
      fm_due: day(flat.fm_due),
      fm_priority: flat.fm_priority,
      fm_attrs: for(%{k: k, v: v} <- flat.attrs, do: %{"k" => id(k), "v" => id(v)}),
      fm_nums: for(%{k: k, n: n} <- flat.nums, do: %{"k" => id(k), "n" => n}),
      fm_dates: for(%{k: k, t: t} <- flat.dates, do: %{"k" => id(k), "t" => t})
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
    |> Map.new(fn {k, v} -> {short(k), v} end)
  end

  defp id(hmac), do: FilterId.from_hmac(hmac)

  defp stable?(nil), do: true
  defp stable?(status), do: OkfFields.normalize_type(status) == "stable"

  defp day(nil), do: nil
  defp day(unix), do: Integer.floor_div(unix, @day)

  defp updated(_note, fm) when is_integer(fm), do: {fm, nil}

  defp updated(note, nil) do
    case note.mtime do
      t when is_number(t) and t > 0 -> {trunc(t), @file_src}
      _ -> {unix(note.updated_at), @server_src}
    end
  end

  # `ctime` lands with #2082 (`notes.ctime`); read defensively until then.
  defp created(_note, fm) when is_integer(fm), do: {fm, nil}

  defp created(note, nil) do
    case Map.get(note, :ctime) do
      t when is_number(t) and t > 0 -> {trunc(t), @file_src}
      _ -> {unix(note.created_at), @server_src}
    end
  end

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
end
