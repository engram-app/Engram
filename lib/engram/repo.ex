defmodule Engram.Repo do
  use Ecto.Repo,
    otp_app: :engram,
    adapter: Ecto.Adapters.Postgres

  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements)a

  @doc """
  Executes `fun` inside a transaction with RLS tenant context set.

  Sets both the process-dict guard (for prepare_query) and the
  PostgreSQL transaction-local `app.current_tenant` (for RLS enforcement).

  `tenant_id` is a canonical UUID string (post PG18+UUIDv7 rework).
  The RLS policy compares `(user_id)::text = current_setting('app.current_tenant')`,
  so the bind value is the lower-case hyphenated UUID string.

  Wire shape: tenant + role drop are applied in ONE parameterized
  `SELECT set_config(...)` (`set_config(..., true)` is exactly SET LOCAL)
  and reset in one — hot requests open several tenant blocks, and the old
  three-utility-statement shape was pure fixed overhead per block.

  Re-entrant: a nested call for the SAME tenant inside an active
  with_tenant transaction runs `fun` directly (the settings are
  transaction-scoped and still in force) and returns `{:ok, result}` for
  shape-compatibility with the transactional path. A nested call for a
  DIFFERENT tenant raises — silently switching RLS identity
  mid-transaction is never legitimate.
  """
  def with_tenant(tenant_id, fun) when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, uuid} ->
        case Process.get(:engram_tenant) do
          ^uuid ->
            if in_transaction?() do
              {:ok, fun.()}
            else
              run_with_tenant(uuid, fun)
            end

          nil ->
            run_with_tenant(uuid, fun)

          other ->
            raise ArgumentError,
                  "with_tenant nested for a different tenant " <>
                    "(active: #{other}, requested: #{uuid})"
        end

      :error ->
        raise ArgumentError,
              "tenant_id must be a canonical UUID string, got: #{inspect(tenant_id)}"
    end
  end

  def with_tenant(tenant_id, _fun) do
    raise ArgumentError,
          "tenant_id must be a canonical UUID string, got: #{inspect(tenant_id)}"
  end

  defp run_with_tenant(uuid, fun) do
    Process.put(:engram_tenant, uuid)

    try do
      transaction(fn ->
        # `set_config(..., true)` == SET LOCAL, but as a regular SELECT it
        # takes a bind parameter (no string interpolation) and applies the
        # tenant + the engram_app role drop in a single round trip.
        # Superusers bypass RLS even with FORCE — the role drop scopes
        # enforcement to this transaction.
        _ =
          query!(
            "SELECT set_config('app.current_tenant', $1, true), " <>
              "set_config('role', 'engram_app', true)",
            [uuid]
          )

        result = fun.()
        # In Ecto Sandbox (tests), this transaction runs as a savepoint.
        # PostgreSQL's transaction-local settings span the full outer
        # transaction, so RELEASE SAVEPOINT would leak `engram_app` into
        # the sandbox transaction. Resetting the role INSIDE the
        # transaction (`set_config('role', 'none', true)` == SET LOCAL
        # ROLE NONE) ensures the last local setting that persists is the
        # default. In production this runs inside a real transaction and
        # is harmless.
        _ = query!("SELECT set_config('role', 'none', true)")
        result
      end)
    after
      Process.delete(:engram_tenant)
    end
  end

  @doc """
  Safety net — raises if a tenant-scoped table is queried without
  `with_tenant/2`. Uses process dict (zero-cost) rather than a DB query.
  """
  @impl true
  def prepare_query(_operation, query, opts) do
    if tenant_required?(query) and is_nil(Process.get(:engram_tenant)) and
         not Keyword.get(opts, :skip_tenant_check, false) do
      raise Engram.TenantError,
        message: "Tenant context not set! Use Repo.with_tenant/2 for tenant-scoped queries."
    end

    {query, opts}
  end

  @tenant_table_strings Enum.map(@tenant_tables, &Atom.to_string/1)

  defp tenant_required?(%Ecto.Query{from: %{source: {table, _}}}) do
    table in @tenant_table_strings
  end

  defp tenant_required?(_), do: false
end
