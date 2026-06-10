defmodule Engram.Repo do
  use Ecto.Repo,
    otp_app: :engram,
    adapter: Ecto.Adapters.Postgres

  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements)a

  @doc """
  Executes `fun` inside a transaction with RLS tenant context set.

  Sets both the process-dict guard (for prepare_query) and the
  PostgreSQL `SET LOCAL app.current_tenant` (for RLS enforcement).

  `tenant_id` is a canonical UUID string (post PG18+UUIDv7 rework).
  The RLS policy compares `(user_id)::text = current_setting('app.current_tenant')`,
  so the bind value is the lower-case hyphenated UUID string.
  """
  def with_tenant(tenant_id, fun) when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, uuid} ->
        Process.put(:engram_tenant, uuid)

        try do
          transaction(fn ->
            # SET LOCAL doesn't support $1 parameter binding — it's a utility statement.
            # `uuid` was validated by `Ecto.UUID.cast/1` above: lower-case hex with
            # hyphens, no quotes, no injection surface.
            _ = query!("SET LOCAL app.current_tenant = '#{uuid}'")
            # Drop to engram_app role so RLS policies are enforced.
            # Superusers bypass RLS even with FORCE — SET LOCAL ROLE scopes to this transaction.
            _ = query!("SET LOCAL ROLE engram_app")
            result = fun.()
            # In Ecto Sandbox (tests), this transaction runs as a savepoint. PostgreSQL's
            # SET LOCAL is scoped to the full outer transaction, so RELEASE SAVEPOINT
            # would leak `engram_app` into the sandbox transaction. Resetting the role
            # INSIDE the transaction ensures the last SET LOCAL that persists is DEFAULT.
            # In production this runs inside a real transaction and is harmless.
            _ = query!("RESET ROLE")
            result
          end)
        after
          Process.delete(:engram_tenant)
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
