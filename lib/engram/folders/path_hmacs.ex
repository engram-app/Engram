defmodule Engram.Folders.PathHmacs do
  @moduledoc """
  The ONE writer of `folders.full_path_hmac` (`FullPathHmacWriterLintTest`
  fails on a write anywhere else).

  Release 0.89.0 finds folders by this hash and keys a map by it, so during
  a mixed-version window two live rows with one hash make its lookup pick
  either (S6 step 3, Engram#2523). Every write therefore keeps one live row
  per hash per vault:

    * `put/2`: a writer that knows a row's CURRENT path hash takes it from
      any other live row still holding it (a stale hash, left below a folder
      whose rename could not rewrite it), then sets it. That row then reads
      as "no hash", which 0.89.0 repairs on its next ensure and D never reads.
    * `yield/2`: rows whose stored hash may be stale (a restore revives a row
      as it was) drop it when another live row holds it.

  One statement each, on `folders_full_path` (vault_id, full_path_hmac).
  Runs on the caller's connection: `Engram.Repo` inside a tenant
  transaction, or a maintenance repo (`repo` argument). Dropped with the
  column.
  """

  alias Engram.Repo

  @put """
  WITH t AS (
    SELECT v.id, v.fh, f.vault_id
    FROM unnest($1::uuid[], $2::bytea[]) AS v(id, fh)
    JOIN folders f ON f.id = v.id AND f.user_id = $3
    WHERE f.id = ANY($1::uuid[])
  ), released AS (
    UPDATE folders h SET full_path_hmac = NULL
    FROM t
    WHERE h.vault_id = t.vault_id AND h.full_path_hmac = t.fh AND h.user_id = $3
      AND h.deleted_at IS NULL AND h.id <> ALL($1::uuid[])
    RETURNING h.id
  )
  UPDATE folders f SET full_path_hmac = t.fh, updated_at = now()
  FROM t
  WHERE f.id = t.id AND f.id = ANY($1::uuid[]) AND f.user_id = $3
    AND f.full_path_hmac IS DISTINCT FROM t.fh
  """

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
  Sets each `{id, hash}` of `user_id`'s rows (a nil hash is skipped), first
  releasing that hash from any other live row of the same vault. Returns
  the rows set.
  """
  @spec put(module(), Ecto.UUID.t(), [{Ecto.UUID.t() | binary(), binary() | nil}]) ::
          non_neg_integer()
  def put(repo \\ Repo, user_id, pairs) do
    case for({id, h} <- pairs, is_binary(h), do: {uuid(id), h}) do
      [] ->
        0

      pairs ->
        {ids, hmacs} = Enum.unzip(pairs)
        %{num_rows: n} = repo.query!(@put, [ids, hmacs, uuid(user_id)])
        n
    end
  end

  @doc "The rows of `vault_id` among `ids` drop a hash another live row of the vault holds."
  @spec yield(module(), Ecto.UUID.t(), [Ecto.UUID.t() | binary()]) :: non_neg_integer()
  def yield(repo \\ Repo, vault_id, ids)
  def yield(_repo, _vault_id, []), do: 0

  def yield(repo, vault_id, ids) do
    %{num_rows: n} = repo.query!(@yield, [Enum.map(ids, &uuid/1), uuid(vault_id)])
    n
  end

  defp uuid(<<_::128>> = raw), do: raw
  defp uuid(id) when is_binary(id), do: Ecto.UUID.dump!(id)
end
