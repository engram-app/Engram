defmodule Engram.Notes.Keys do
  @moduledoc """
  Which `notes` columns a lookup filters on: the 32-byte HMACs, or wave 3's
  16-byte ids (`path_id` = the first 16 bytes of `path_hmac`, a uuid;
  migration 20261021110000) and their `(vault_id, ...)` partial indexes
  (20261021110300).

  The ids are filled by a trigger on every write and, for older rows, by the
  `NoteSplit` data migration. Until that ledger is done a row may lack them,
  so every lookup filters on the HMACs; once it is, on the ids. The answer is
  cached per node for a minute (`:note_split` cache), so a lookup costs no
  query.

  Only FILTERS switch. Projections (`select`) keep the HMAC columns, which
  every row still carries.
  """
  import Ecto.Query

  alias Engram.DataMigrations

  @cols %{
    path: {:path_hmac, :path_id},
    folder: {:folder_hmac, :folder_id},
    basename: {:basename_hmac, :basename_id},
    path_ci: {:path_ci_hmac, :path_ci_id},
    type: {:type_hmac, :type_id}
  }

  @typedoc "The key families `notes` carries both ways."
  @type kind :: :path | :folder | :basename | :path_ci | :type

  @doc "True once every row carries its ids (the `note_split` ledger is done)."
  @spec ids?() :: boolean()
  def ids? do
    Engram.Cache.fetch(:note_split, :done, fn ->
      DataMigrations.done?(Engram.DataMigrations.NoteSplit.name(), 1)
    end)
  end

  @doc "The column a lookup of `kind` compares."
  @spec col(kind()) :: atom()
  def col(kind), do: kind |> pick() |> elem(0)

  @doc "What that column holds for a key whose HMAC is `hmac`."
  @spec value(kind(), binary()) :: binary()
  def value(kind, hmac) when is_binary(hmac), do: kind |> pick() |> elem(1) |> then(& &1.(hmac))

  @doc "`binding.<kind> == hmac`, on the ids when they are complete."
  @spec eq(kind(), binary()) :: Ecto.Query.dynamic_expr()
  def eq(kind, hmac) do
    {column, to_value} = pick(kind)
    value = to_value.(hmac)
    dynamic([n], field(n, ^column) == ^value)
  end

  @doc "`binding.<kind> IN hmacs`, on the ids when they are complete."
  @spec in_any(kind(), [binary()]) :: Ecto.Query.dynamic_expr()
  def in_any(kind, hmacs) when is_list(hmacs) do
    {column, to_value} = pick(kind)
    values = Enum.map(hmacs, to_value)
    dynamic([n], field(n, ^column) in ^values)
  end

  # One read of the switch per call, so a column and its value always agree.
  defp pick(kind) do
    {hmac_col, id_col} = Map.fetch!(@cols, kind)
    if ids?(), do: {id_col, &id/1}, else: {hmac_col, & &1}
  end

  @doc """
  The live-row predicate the id indexes are partial on (`NOT is_folder` for
  notes, `is_folder` for markers), so a query on the ids can use them.
  `true` while the ids are incomplete: the HMAC indexes key on `kind`.
  """
  @spec kind_match(:note | :folder) :: Ecto.Query.dynamic_expr()
  def kind_match(kind) do
    cond do
      not ids?() -> dynamic(true)
      kind == :note -> dynamic([n], not field(n, :is_folder))
      kind == :folder -> dynamic([n], field(n, :is_folder))
    end
  end

  @doc "The 16-byte id of an HMAC, as the uuid string Ecto binds."
  @spec id(binary()) :: Ecto.UUID.t()
  def id(<<head::binary-16, _::binary>>), do: Ecto.UUID.load!(head)
end
