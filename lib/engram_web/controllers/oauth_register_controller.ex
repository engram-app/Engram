defmodule EngramWeb.OAuthRegisterController do
  @moduledoc """
  RFC 7591 Dynamic Client Registration. Public, rate-limited.

  Mints public PKCE clients by default — `token_endpoint_auth_method=none`
  with no `client_secret`. Confidential clients can be requested but are
  not yet supported (no secret minting wired up); validation rejects
  `client_secret_post` / `client_secret_basic` to keep the surface
  small until Phase 4 needs it.
  """
  use EngramWeb, :controller

  alias Engram.OAuth

  def register(conn, params) do
    case OAuth.register_client(params) do
      {:ok, client} ->
        conn
        |> put_status(:created)
        |> json(serialize(client))

      {:error, changeset} ->
        {error, description} = changeset_error(changeset)

        conn
        |> put_status(:bad_request)
        |> json(%{error: error, error_description: description})
    end
  end

  defp serialize(client) do
    %{
      client_id: client.client_id,
      client_id_issued_at: DateTime.to_unix(client.inserted_at),
      redirect_uris: client.redirect_uris,
      client_name: client.client_name,
      scope: client.scope,
      grant_types: client.grant_types,
      response_types: client.response_types,
      token_endpoint_auth_method: client.token_endpoint_auth_method
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp changeset_error(changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

    if Map.has_key?(errors, :redirect_uris) do
      {"invalid_redirect_uri", join_errors(errors[:redirect_uris])}
    else
      {"invalid_client_metadata", flat_describe(errors)}
    end
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp join_errors(list) when is_list(list), do: Enum.join(list, "; ")
  defp join_errors(other), do: to_string(other)

  defp flat_describe(errors) when is_map(errors) do
    Enum.map_join(errors, "; ", fn {field, msgs} -> "#{field}: #{join_errors(msgs)}" end)
  end
end
