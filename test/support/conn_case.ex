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

  defdelegate grant_api_write!(user), to: Engram.ApiEntitlementHelpers

  @doc """
  Ensures the user has an `external_id`, which the Local auth provider needs as
  the JWT `sub`. The factory does not set one, so any test minting a real
  session or OAuth token for a factory user must call this first.
  """
  def ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  def ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end

  @doc """
  Test `setup` callback that builds an API-key-authenticated connection:
  inserts a paid (api_write_enabled) user with a default vault, mints an API
  key, and sets the `Bearer` header. Returns `%{conn, user, vault, api_key}`
  to merge into the test context.

  Use as `setup :authed_api_conn`. This collapses the API-key auth boilerplate
  that was copy-pasted across controller tests; files needing extra fixtures
  can call it and augment the returned context.
  """
  def authed_api_conn(%{conn: conn}) do
    user = Engram.Factory.insert(:user)
    vault = Engram.Factory.insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault, api_key: api_key}
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
end
