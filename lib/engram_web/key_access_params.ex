defmodule EngramWeb.KeyAccessParams do
  @moduledoc """
  The `vault_access` / `default_access` pair both API-key creation endpoints
  accept (#332), read the same way the OAuth consent screen's is
  (`Engram.Permissions.parse_access_params/1`). Shared so `POST /api-keys`
  and `POST /connections/pat` cannot disagree about what a valid request is.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @doc "`{:ok, nil | {levels, default}}`, or a halted 422 conn for the fallback to return."
  def parse(conn, params) do
    case Engram.Permissions.parse_access_params(params) do
      {:ok, access} -> {:ok, access}
      :error -> invalid(conn)
    end
  end

  @doc "The 422 for a level, vault or selection the user cannot grant."
  def invalid(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: %{
        vault_access: [
          "each level must be none, read or write, every vault must be one of yours, " <>
            "and the key must reach at least one vault now or later"
        ]
      }
    })
  end
end
