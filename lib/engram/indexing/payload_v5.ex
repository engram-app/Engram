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
  (`cs` = 1) or `created_at` (2): `Engram.Notes.EffectiveDates`. The flags are small integers rather than
  strings to keep a point small.

  A fallback `up` is rounded UP to the next full hour (an exact hour stays):
  it moves on every save, and a moved `up` changes the payload hash, so an
  unrounded one made every index pass of an edited note rewrite its points
  (#2263). Rounded, a note edited all day refreshes them about once an hour.
  Ceil, not floor, so `updated_after` never misses an edit; the cost is that
  date filters on these notes are hour-accurate. A frontmatter `updated` is
  the user's own value and stays exact, as does `cr` (it does not move on
  edit).
  """

  import Engram.Vector.PayloadKeys, only: [short: 1]

  alias Engram.FileTime
  alias Engram.Notes.EffectiveDates
  alias Engram.Notes.FlatFields
  alias Engram.Notes.OkfFields
  alias Engram.Vector.FilterId

  @day 86_400
  @hour 3_600
  # `EffectiveDates`' source flag for the file time.
  @file_src 1

  @spec build(map(), FlatFields.t()) :: %{String.t() => term()}
  def build(note, flat) do
    {up, us} = note |> EffectiveDates.updated(flat.fm_updated) |> ceil_fallback(note)
    {cr, cs} = EffectiveDates.created(note, flat.fm_created)

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
      fm_attrs: user_attrs(flat)
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
    |> Map.new(fn {k, v} -> {short(k), v} end)
  end

  # The hour ceil is the payload's alone: `EffectiveDates` and the Postgres
  # date columns stay exact. A file time is ceiled from its full precision,
  # not the floored second, so `14:00:00.5` is `15:00`.
  defp ceil_fallback({up, nil}, _note), do: {up, nil}
  defp ceil_fallback({nil, src}, _note), do: {nil, src}

  # Seconds: main's formula verbatim on the raw double (hash identity by
  # construction). Milliseconds: from `FileTime`'s full precision.
  defp ceil_fallback({_up, @file_src}, %{mtime: t}) do
    if FileTime.seconds?(t) do
      {ceil(t / @hour) * @hour, @file_src}
    else
      {:ok, at} = FileTime.to_at(t)
      {ceil(DateTime.to_unix(at, :microsecond) / (@hour * 1_000_000)) * @hour, @file_src}
    end
  end

  defp ceil_fallback({up, src}, _note), do: {ceil(up / @hour) * @hour, src}

  defp id(hmac), do: FilterId.from_hmac(hmac)

  # One nested entry per user-added value, keyed by the per-user dictionary
  # id; a key without an id (past the cap) is left out.
  defp user_attrs(%{key_ids: ids} = flat) do
    for(%{k: k, v: v} <- flat.attrs, Map.has_key?(ids, k), do: %{"k" => ids[k], "h" => id(v)}) ++
      for(%{k: k, n: n} <- flat.nums, Map.has_key?(ids, k), do: %{"k" => ids[k], "n" => n}) ++
      for %{k: k, t: t} <- flat.dates, Map.has_key?(ids, k), do: %{"k" => ids[k], "d" => t}
  end

  defp stable?(nil), do: true
  defp stable?(status), do: OkfFields.normalize_type(status) == "stable"

  defp day(nil), do: nil
  defp day(unix), do: Integer.floor_div(unix, @day)
end
