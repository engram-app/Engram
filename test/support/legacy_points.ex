defmodule Engram.LegacyPoints do
  @moduledoc """
  Turns a note the writer just indexed (v5 layout) into what a pre-v5 (v3)
  writer left behind, for tests of the readers that still serve that layout
  while `:legacy_filter_fields` is on (self-host collections keep v3 points
  until each note is rewritten).

  A v3 index: random point ids on the chunk rows, no `chunk_points` rows, and
  points whose payload is the legacy note payload
  (`Engram.Indexing.expected_note_payload/1`) plus the chunk text, title and
  heading encrypted per point (`Engram.Crypto.encrypt_qdrant_payload/4`).
  """
  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes.{Chunk, ChunkPoint, Note}
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  @doc """
  Re-keys `note`'s index to v3 points. `store` is a fake Qdrant Agent whose
  state holds `points` (`%{id => payload}`) and optionally `vectors`: the
  v5 points are dropped and v3 ones written under the new ids (vectors
  move with their point). Returns `%{old_id => new_id}`.
  """
  @spec rekey!(Note.t(), Engram.Accounts.User.t(), pid()) :: %{String.t() => String.t()}
  def rekey!(%{id: note_id}, user, store) do
    raw = Repo.one!(from(n in Note, where: n.id == ^note_id), skip_tenant_check: true)
    {:ok, plain} = Crypto.maybe_decrypt_note_fields(raw, user)

    chunks =
      Repo.all(from(c in Chunk, where: c.note_id == ^note_id and not is_nil(c.qdrant_point_id)),
        skip_tenant_check: true
      )

    remap = Map.new(chunks, &{&1.qdrant_point_id, Ecto.UUID.generate()})

    {:ok, _} =
      Repo.with_tenant(raw.user_id, fn ->
        Repo.delete_all(from(p in ChunkPoint, where: p.note_id == ^note_id))

        for {old, new} <- remap do
          Repo.update_all(
            from(c in Chunk, where: c.note_id == ^note_id and c.qdrant_point_id == ^old),
            set: [qdrant_point_id: new]
          )
        end
      end)

    legacy =
      Map.new(chunks, fn chunk ->
        id = Map.fetch!(remap, chunk.qdrant_point_id)
        {id, legacy_payload(raw, plain, chunk, user, id)}
      end)

    Agent.update(store, fn s ->
      s
      |> Map.update!(:points, &(&1 |> Map.drop(Map.keys(remap)) |> Map.merge(legacy)))
      |> remap_vectors(remap)
    end)

    remap
  end

  defp legacy_payload(raw, plain, chunk, user, id) do
    # A frontmatter chunk has `char_end` 0: its slice is empty.
    from = chunk.char_start || 0
    text = String.slice(plain.content || "", from, max((chunk.char_end || 0) - from, 0))

    base =
      raw
      |> Indexing.expected_note_payload()
      |> Map.merge(%{title: plain.title, heading_path: nil, text: text})

    {:ok, payload} = Crypto.encrypt_qdrant_payload(base, user, Qdrant.collection_name(), id)
    payload |> Jason.encode!() |> Jason.decode!()
  end

  defp remap_vectors(%{vectors: vectors} = s, remap),
    do: %{s | vectors: Map.new(vectors, fn {id, v} -> {Map.get(remap, id, id), v} end)}

  defp remap_vectors(s, _remap), do: s
end
