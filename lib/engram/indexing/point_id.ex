defmodule Engram.Indexing.PointId do
  @moduledoc """
  Deterministic Qdrant point ids for v5 points: UUIDv5 over
  `note_id <> ":" <> fingerprint <> ":" <> ordinal`, in a fixed namespace.
  The ordinal is the index of a fingerprint among equal fingerprints in the
  note, in position order, so inserting a chunk above leaves the ids below
  unchanged and a rebuild of unchanged content rewrites the same ids.
  """

  # Fixed forever: changing it renames every v5 point.
  @namespace "5b0a7f0e-2c39-4f7e-9d1a-6a0c3e8f4b21"

  @spec namespace_v5() :: Ecto.UUID.t()
  def namespace_v5, do: @namespace

  @spec v5(Ecto.UUID.t(), binary() | nil, non_neg_integer()) :: Ecto.UUID.t()
  def v5(note_id, fingerprint, ordinal) do
    fp = Base.encode16(fingerprint || "", case: :lower)
    uuid5(@namespace, "#{note_id}:#{fp}:#{ordinal}")
  end

  @doc """
  `v5/3` at the first ordinal from `ordinal` up whose id is not in `taken`.
  Keeps a new point from reusing an id a kept point already holds.
  """
  @spec free_v5(Ecto.UUID.t(), binary() | nil, non_neg_integer(), MapSet.t()) :: Ecto.UUID.t()
  def free_v5(note_id, fingerprint, ordinal, taken) do
    id = v5(note_id, fingerprint, ordinal)
    if MapSet.member?(taken, id), do: free_v5(note_id, fingerprint, ordinal + 1, taken), else: id
  end

  @doc "Ordinal of each fingerprint among the equal ones before it."
  @spec ordinals([binary() | nil]) :: [non_neg_integer()]
  def ordinals(fingerprints) do
    {ords, _seen} =
      Enum.map_reduce(fingerprints, %{}, fn fp, seen ->
        n = Map.get(seen, fp, 0)
        {n, Map.put(seen, fp, n + 1)}
      end)

    ords
  end

  @doc false
  # RFC 4122 section 4.3 name-based UUID, SHA-1.
  def uuid5(namespace, name) do
    {:ok, ns} = Ecto.UUID.dump(namespace)
    <<a::48, _v::4, b::12, _var::2, c::62, _::binary>> = :crypto.hash(:sha, ns <> name)
    Ecto.UUID.cast!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end
end
