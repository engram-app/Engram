defmodule Engram.Crypto.TenantSweep do
  @moduledoc """
  Per-user id-cursor sweep over one tenant table, in batches of 200, each batch
  inside that user's RLS context. Shared by DEK rotation
  (`Engram.Crypto.UserDekRotation`) and the envelope re-encode
  (`Engram.Workers.ReencodeEnvelopes`).

  Every table swept through here carries FORCE ROW LEVEL SECURITY, so the
  cursor read and the batch's writes both need `app.current_tenant` set.
  The `skip_tenant_check` option only silences Engram's own `prepare_query/3`
  guard; it sets nothing in Postgres and does not scope the query. Without
  the `with_tenant` wrapper the cursor matches zero rows for every user, the
  `[] -> :ok` clause reads that as "nothing left to sweep", and a rotation
  reports success having re-encrypted nothing while its `final_flip/3` still
  lands (`users` has no RLS). Unrecoverable once the old key is retired.

  Wrapped per batch rather than per sweep: `with_tenant/2` opens a
  transaction, and one transaction spanning an entire table would hold every
  row lock for the duration of the sweep.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Repo

  @batch_size 200
  @first_id "00000000-0000-0000-0000-000000000000"

  @doc """
  Calls `fun` with each batch of the user's row ids (ascending), inside the
  user's tenant context. `fun` returns `:ok` to continue, `{:halt, value}` to
  stop early (returned as is, the batch commits), or `{:error, _}` to stop;
  the first error is returned.

  Options: `:after` resumes after that id (default: from the start),
  `:batch_size` (default 200).
  """
  def each_batch(user_id, schema, fun, opts \\ []) do
    after_id = Keyword.get(opts, :after) || @first_id
    loop(user_id, schema, after_id, fun, Keyword.get(opts, :batch_size, @batch_size))
  end

  defp loop(user_id, schema, last_id, fun, size) do
    swept =
      Repo.with_tenant(user_id, fn ->
        case fetch_batch_ids(user_id, schema, last_id, size) do
          [] -> :done
          ids -> {:batch, ids, fun.(ids)}
        end
      end)

    case swept do
      {:ok, :done} -> :ok
      {:ok, {:batch, ids, :ok}} -> loop(user_id, schema, List.last(ids), fun, size)
      {:ok, {:batch, _ids, {:halt, _} = halt}} -> halt
      {:ok, {:batch, _ids, {:error, _} = err}} -> err
      {:error, reason} -> {:error, reason}
    end
  end

  # Notes are scoped via vault.user_id AND directly via user_id; use user_id directly.
  defp fetch_batch_ids(user_id, Engram.Notes.Note, last_id, size) do
    from(n in Engram.Notes.Note,
      where: n.user_id == ^user_id,
      where: n.id > ^last_id,
      order_by: n.id,
      limit: ^size,
      select: n.id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Keyed by vault_id, not id: the generic clause below orders by `r.id`, which
  # this table does not have.
  defp fetch_batch_ids(user_id, Engram.Notes.VaultIndexState, last_id, size) do
    from(s in Engram.Notes.VaultIndexState,
      where: s.user_id == ^user_id,
      where: s.vault_id > ^last_id,
      order_by: s.vault_id,
      limit: ^size,
      select: s.vault_id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Default fallback for schemas with a direct user_id column.
  defp fetch_batch_ids(user_id, schema, last_id, size) do
    from(r in schema,
      where: r.user_id == ^user_id,
      where: r.id > ^last_id,
      order_by: r.id,
      limit: ^size,
      select: r.id
    )
    |> Repo.all(skip_tenant_check: true)
  end
end
