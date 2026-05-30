defmodule EngramWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use EngramWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint EngramWeb.Endpoint

      use EngramWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import EngramWeb.ConnCase
      import Engram.Factory
    end
  end

  setup tags do
    Engram.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Grants the user paid-tier API access via `user_limit_overrides` rows:
  `api_write_enabled=true` and a generous `api_rps_cap=1000`. Use in
  setup blocks for tests that exercise API-key write paths — pricing v2
  §G gates non-GET requests on the write flag AND every API-key request
  on the RPS cap when authed via API key, so any test minting a key for
  controller use must represent a paid user.

  Returns `user` unchanged for pipe-friendliness.
  """
  def grant_api_write!(%Engram.Accounts.User{} = user) do
    upsert_override!(user, "api_write_enabled", true)
    upsert_override!(user, "api_rps_cap", 1_000)
    user
  end

  @doc "Signs `user` in by minting a local access token and setting the Bearer header."
  def authenticate(conn, user) do
    # `user_factory` defaults `external_id: nil`; the access token's `sub` claim
    # must be a real external_id so `TokenResolver` resolves it back to this row.
    user =
      if is_nil(user.external_id) do
        {:ok, persisted} =
          user
          |> Ecto.Changeset.change(external_id: Ecto.UUID.generate())
          |> Engram.Repo.update(skip_tenant_check: true)

        persisted
      else
        user
      end

    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # Idempotent insert — the helper may be called multiple times against the
  # same user when a test exercises more than one `create_api_key` flow.
  defp upsert_override!(user, key, value) do
    case Engram.Repo.get_by(Engram.Billing.UserLimitOverride, user_id: user.id, key: key) do
      nil ->
        Engram.Factory.insert(:user_limit_override,
          user: user,
          key: key,
          value: %{"v" => value}
        )

      _existing ->
        :noop
    end
  end
end
