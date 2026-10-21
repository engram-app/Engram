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

  alias Engram.DataMigrations.Entry
  alias Engram.Repo

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
    # Read from the ledger table itself, not `DataMigrations.done?/2`, whose
    # `true` is kept for the node's lifetime: a re-verify that reopens the
    # migration (rows found without ids) must turn the ids off on every node
    # within the minute, or lookups would miss rows that exist.
    Engram.Cache.fetch(:note_split, :done, fn ->
      Repo.exists?(
        from(e in Entry,
          where:
            e.name == ^Engram.DataMigrations.NoteSplit.name() and e.version >= 1 and
              not is_nil(e.completed_at)
        )
      )
    end)
  end

  @doc "The column a lookup of `kind` compares."
  @spec col(kind()) :: atom()
  def col(kind), do: kind |> pick() |> elem(0)

  @doc "What that column holds for a key whose HMAC is `hmac`."
  @spec value(kind(), binary()) :: binary()
  def value(kind, hmac) when is_binary(hmac), do: kind |> pick() |> elem(1) |> then(& &1.(hmac))

  @doc """
  `binding.<kind> == hmac`, on the ids when they are complete.

  A query that also uses `kind_match/2` passes one `ids?()` read to both, so
  the filter and the partial-index predicate agree even if the cache turns
  over between the two calls.
  """
  @spec eq(kind(), binary(), boolean()) :: Ecto.Query.dynamic_expr()
  def eq(kind, hmac, ids? \\ ids?()) do
    {column, to_value} = pick(kind, ids?)
    value = to_value.(hmac)
    dynamic([n], field(n, ^column) == ^value)
  end

  @doc "`binding.<kind> IN hmacs`, on the ids when they are complete."
  @spec in_any(kind(), [binary()], boolean()) :: Ecto.Query.dynamic_expr()
  def in_any(kind, hmacs, ids? \\ ids?()) when is_list(hmacs) do
    {column, to_value} = pick(kind, ids?)
    values = Enum.map(hmacs, to_value)
    dynamic([n], field(n, ^column) in ^values)
  end

  # One read of the switch per call, so a column and its value always agree.
  defp pick(kind, ids? \\ ids?()) do
    {hmac_col, id_col} = Map.fetch!(@cols, kind)
    if ids?, do: {id_col, &id/1}, else: {hmac_col, & &1}
  end

  @doc """
  The live-row predicate the id indexes are partial on (`NOT is_folder` for
  notes, `is_folder` for markers), so a query on the ids can use them.
  `true` while the ids are incomplete: the HMAC indexes key on `kind`.
  """
  @spec kind_match(:note | :folder, boolean()) :: Ecto.Query.dynamic_expr()
  def kind_match(kind, ids? \\ ids?()) do
    cond do
      not ids? -> dynamic(true)
      kind == :note -> dynamic([n], not field(n, :is_folder))
      kind == :folder -> dynamic([n], field(n, :is_folder))
    end
  end

  @doc "The 16-byte id of an HMAC, as the uuid string Ecto binds."
  @spec id(binary()) :: Ecto.UUID.t()
  def id(<<head::binary-16, _::binary>>), do: Ecto.UUID.load!(head)
  # A malformed key (a corrupt job arg) matches no row, as its HMAC did; a
  # real HMAC is 32 bytes, and none derives the all-zero id.
  def id(_short), do: "00000000-0000-0000-0000-000000000000"
end
