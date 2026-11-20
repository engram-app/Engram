defmodule Engram.Folders.PathHmacs do
  @moduledoc """
  The ONE writer of `folders.full_path_hmac` (`FullPathHmacWriterLintTest`
  fails on a write anywhere else).

  Release 0.89.0 finds folders by this hash and keys a map by it, so during
  a mixed-version window two live rows with one hash make its lookup pick
  either (S6 step 3, Engram#2523). Every write therefore keeps one live row
  per hash per vault:

    * `put/3`: a writer that knows a row's CURRENT path hash takes it from
      any other live row still holding it (a stale hash, left below a folder
      whose rename could not rewrite it), then sets it. That row then reads
      as "no hash", which 0.89.0 repairs on its next ensure and D never reads.
      A dead target only sets its own hash: it never costs a live row one.
    * `with_hash/2` + `release/3`: a new row carries its hash in its INSERT
      (written once), then the hash is released from other holders.
    * `yield/3`: a revived row whose current path will not resolve (a name
      that will not decrypt) drops a hash another live row holds.

  One statement each, on `folders_full_path` (vault_id, full_path_hmac).
  Runs on the caller's connection: `Engram.Repo` inside a tenant
  transaction, or a maintenance repo (`repo` argument). Dropped with the
  column.
  """

  alias Engram.Repo

  # Live targets only release: a dead row's hash names no folder a reader
  # can reach, so it must never cost a live row its hash (a DEK rotation
  # re-keys dead rows too, in chunks).
  @targets """
  SELECT v.id, v.fh, f.vault_id, f.deleted_at IS NULL AS live
  FROM unnest($1::uuid[], $2::bytea[]) AS v(id, fh)
  JOIN folders f ON f.id = v.id AND f.user_id = $3
  WHERE f.id = ANY($1::uuid[])
  """

  @release_from """
  UPDATE folders h SET full_path_hmac = NULL
  FROM t
  WHERE t.live AND h.vault_id = t.vault_id AND h.full_path_hmac = t.fh AND h.user_id = $3
    AND h.deleted_at IS NULL AND h.id <> ALL($1::uuid[])
  """

  @put """
  WITH t AS (#{@targets}), released AS (#{@release_from} RETURNING h.id)
  UPDATE folders f SET full_path_hmac = t.fh, updated_at = now()
  FROM t
  WHERE f.id = t.id AND f.id = ANY($1::uuid[]) AND f.user_id = $3
    AND f.full_path_hmac IS DISTINCT FROM t.fh
  """

  @release "WITH t AS (#{@targets}) #{@release_from}"

  @yield """
  UPDATE folders r SET full_path_hmac = NULL
  WHERE r.id = ANY($1::uuid[]) AND r.vault_id = $2 AND r.full_path_hmac IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM folders o
      WHERE o.vault_id = $2 AND o.full_path_hmac = r.full_path_hmac
        AND o.deleted_at IS NULL AND o.id <> r.id
    )
  """

  # Plan shape (`PathHmacsPlanTest`): the rows written are named by
  # `id = ANY($1)` as well as joined to the unnest (an unnest is estimated
  # at 100 rows, which made a tenant scan look cheaper than primary-key
  # probes), and the owner is bound (`user_id`, or the vault for `yield/3`).
  # Every read is then a primary-key or `folders_full_path` probe.

  @doc """
  The `set:` keywords that clear a row's hash, for a writer that must drop
  it in its own UPDATE (a restore with S6 step 3's write stop on): no
  release needed, a NULL hash is held by no one.
  """
  @spec cleared() :: keyword()
  def cleared, do: [full_path_hmac: nil]

  @doc """
  An insert row (a map for `Repo.insert_all/3`) carrying `hash`: the one
  place a new folder row gets it, so it is written once. The caller then
  runs `release/3` for the rows it inserted, in the same transaction.
  """
  @spec with_hash(map(), binary() | nil) :: map()
  def with_hash(row, hash), do: Map.put(row, :full_path_hmac, hash)

  @doc """
  Releases each `{id, hash}` (a nil hash is skipped) from any other live row
  of the vault, for rows that already carry it (`with_hash/2`). Only a live
  target releases.
  """
  @spec release(module(), Ecto.UUID.t(), [{Ecto.UUID.t() | binary(), binary() | nil}]) ::
          {:ok, non_neg_integer()}
  def release(repo \\ Repo, user_id, pairs), do: run(repo, @release, user_id, pairs)

  @doc """
  Sets each `{id, hash}` of `user_id`'s rows (a nil hash is skipped), first
  releasing that hash from any other live row of the same vault (only
  for a live target). Returns `{:ok, rows set}`. Dropping nil pairs is
  what keeps rows hashless under `Engram.Folders.PathHashStop`: there every
  writer's hash is nil (`Rows`' `full_h`), a marker's (`put_marker_hashes`)
  included, so no caller needs its own stop check.
  """
  @spec put(module(), Ecto.UUID.t(), [{Ecto.UUID.t() | binary(), binary() | nil}]) ::
          {:ok, non_neg_integer()}
  def put(repo \\ Repo, user_id, pairs) do
    run(repo, @put, user_id, pairs)
  end

  defp run(repo, sql, user_id, pairs) do
    case for({id, h} <- pairs, is_binary(h), do: {uuid(id), h}) do
      [] ->
        {:ok, 0}

      pairs ->
        {ids, hmacs} = Enum.unzip(pairs)
        %{num_rows: n} = repo.query!(sql, [ids, hmacs, uuid(user_id)])
        {:ok, n}
    end
  end

  @doc "The rows of `vault_id` among `ids` drop a hash another live row of the vault holds."
  @spec yield(module(), Ecto.UUID.t(), [Ecto.UUID.t() | binary()]) :: {:ok, non_neg_integer()}
  def yield(repo \\ Repo, vault_id, ids)
  def yield(_repo, _vault_id, []), do: {:ok, 0}

  def yield(repo, vault_id, ids) do
    %{num_rows: n} = repo.query!(@yield, [Enum.map(ids, &uuid/1), uuid(vault_id)])
    {:ok, n}
  end

  defp uuid(<<_::128>> = raw), do: raw
  defp uuid(id) when is_binary(id), do: Ecto.UUID.dump!(id)
end
