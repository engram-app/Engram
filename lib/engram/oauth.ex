defmodule Engram.OAuth do
  @moduledoc """
  High-level context for the OAuth 2.1 authorization server.

  Today: Dynamic Client Registration (RFC 7591). Phases 3-6 of the
  MCP OAuth plan add authorization codes, tokens, and revocation.

  `oauth_clients` is intentionally not RLS-tenanted — clients self-
  register pre-login. Lookup is by `client_id` (UUID).
  """
  import Ecto.Query
  alias Engram.OAuth.Client
  alias Engram.Repo

  @doc """
  Register a new OAuth client per RFC 7591. Returns `{:ok, client}` or
  `{:error, changeset}`. Public clients have no secret; confidential
  clients aren't issued today (caller can't request `client_secret_post`
  without us minting + hashing a secret, which we don't yet wire up).
  """
  def register_client(attrs) do
    %Client{}
    |> Client.registration_changeset(attrs)
    |> Repo.insert(skip_tenant_check: true)
  end

  @doc """
  Look up a registered client by `client_id`. Returns `{:ok, client}` or
  `{:error, :not_found}`. Skips RLS — `oauth_clients` is shared.
  """
  def get_client(client_id) when is_binary(client_id) do
    case Ecto.UUID.cast(client_id) do
      {:ok, _} ->
        case Repo.one(from(c in Client, where: c.client_id == ^client_id),
               skip_tenant_check: true
             ) do
          nil -> {:error, :not_found}
          client -> {:ok, client}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_client(_), do: {:error, :not_found}
end
