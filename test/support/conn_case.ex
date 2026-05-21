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
  Grants the user the `api_write_enabled` feature via a
  `user_limit_overrides` row. Use in setup blocks for tests that exercise
  API-key write paths — pricing v2 §G gates non-GET requests on this flag
  when the request is authed via API key, so any test minting a key for a
  write-side controller must represent a paid user.

  Returns `user` unchanged for pipe-friendliness.
  """
  def grant_api_write!(%Engram.Accounts.User{} = user) do
    Engram.Factory.insert(:user_limit_override,
      user: user,
      key: "api_write_enabled",
      value: %{"v" => true}
    )

    user
  end
end
