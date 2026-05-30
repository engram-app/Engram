defmodule Engram.OAuth.Client do
  @moduledoc """
  Schema for an OAuth 2.1 client registered via Dynamic Client Registration
  (RFC 7591). Public clients (PKCE-only) carry no secret. Confidential
  clients are not used today but the schema accommodates them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:client_id, :binary_id, autogenerate: true}
  # Only public PKCE clients are supported until confidential-client minting
  # ships (Phase 4). Reject client_secret_* to avoid handing back a 201 with
  # no secret — a broken half-state for the caller.
  @valid_auth_methods ~w(none)
  @valid_grant_types ~w(authorization_code refresh_token)
  @valid_response_types ~w(code)
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  schema "oauth_clients" do
    field :client_secret_hash, :string
    field :redirect_uris, {:array, :string}
    field :client_name, :string
    field :scope, :string

    field :grant_types, {:array, :string}, default: ["authorization_code", "refresh_token"]

    field :response_types, {:array, :string}, default: ["code"]
    field :token_endpoint_auth_method, :string, default: "none"
    field :software_id, :string
    field :software_version, :string

    # RFC 7591 §2 optional metadata. HTTPS-only per #282.
    field :logo_uri, :string
    field :tos_uri, :string
    field :policy_uri, :string

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(redirect_uris client_name scope grant_types response_types
                  token_endpoint_auth_method software_id software_version
                  logo_uri tos_uri policy_uri)a

  @metadata_uri_fields ~w(logo_uri tos_uri policy_uri)a

  def registration_changeset(client, attrs) do
    client
    |> cast(attrs, @cast_fields)
    |> apply_defaults()
    |> ensure_redirect_uris_present()
    |> validate_redirect_uris()
    |> validate_subset(:grant_types, @valid_grant_types,
      message: "contains an unsupported grant_type"
    )
    |> validate_subset(:response_types, @valid_response_types,
      message: "contains an unsupported response_type"
    )
    |> validate_inclusion(:token_endpoint_auth_method, @valid_auth_methods,
      message: "must be one of: #{Enum.join(@valid_auth_methods, ", ")}"
    )
    |> validate_length(:client_name, max: 200)
    # Attacker-controlled on a public, unauthenticated endpoint; both are
    # persisted and emitted in DCR telemetry, so cap to bound row/metadata size.
    |> validate_length(:software_id, max: 255)
    |> validate_length(:software_version, max: 255)
    |> validate_metadata_uris()
  end

  defp validate_metadata_uris(changeset) do
    Enum.reduce(@metadata_uri_fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        case parse_https_uri(value) do
          :ok -> []
          {:error, msg} -> [{field, msg}]
        end
      end)
    end)
  end

  defp parse_https_uri(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> :ok
      {:ok, %URI{scheme: "https"}} -> {:error, "missing host"}
      {:ok, %URI{scheme: nil}} -> {:error, "missing scheme"}
      {:ok, %URI{scheme: scheme}} -> {:error, "scheme must be https, got #{scheme}"}
      {:error, _} -> {:error, "invalid URI"}
    end
  end

  defp parse_https_uri(_), do: {:error, "must be a string"}

  defp ensure_redirect_uris_present(changeset) do
    case get_field(changeset, :redirect_uris) do
      nil -> add_error(changeset, :redirect_uris, "is required")
      [] -> add_error(changeset, :redirect_uris, "must include at least one URI")
      _ -> changeset
    end
  end

  defp apply_defaults(changeset) do
    changeset
    |> put_default(:grant_types, ["authorization_code", "refresh_token"])
    |> put_default(:response_types, ["code"])
    |> put_default(:token_endpoint_auth_method, "none")
  end

  defp put_default(changeset, field, default) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default)
      [] -> put_change(changeset, field, default)
      _ -> changeset
    end
  end

  defp validate_redirect_uris(changeset) do
    validate_change(changeset, :redirect_uris, fn :redirect_uris, uris ->
      cond do
        not is_list(uris) -> [redirect_uris: "must be a list"]
        uris == [] -> [redirect_uris: "must include at least one URI"]
        true -> uris |> Enum.flat_map(&check_uri/1) |> Enum.uniq()
      end
    end)
  end

  defp check_uri(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: nil}} ->
        [redirect_uris: "missing scheme: #{uri}"]

      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        []

      {:ok, %URI{scheme: "http", host: host}} when host in @loopback_hosts ->
        []

      {:ok, %URI{scheme: "http"}} ->
        [redirect_uris: "non-loopback http is not allowed: #{uri}"]

      {:ok, %URI{scheme: scheme}} when scheme in ["javascript", "data", "file"] ->
        [redirect_uris: "unsafe scheme #{scheme}: #{uri}"]

      {:ok, %URI{scheme: scheme, host: host}} when is_binary(scheme) and scheme != "" ->
        # Native app custom scheme (e.g. com.cursor.app://callback). Must
        # have a reverse-DNS-like dot in the scheme to avoid weak schemes
        # like `myapp://` per RFC 8252 §7.1.
        if String.contains?(scheme, ".") or host in @loopback_hosts do
          []
        else
          [redirect_uris: "weak custom scheme #{scheme}: #{uri}"]
        end

      _ ->
        [redirect_uris: "invalid URI: #{uri}"]
    end
  end

  defp check_uri(_), do: [redirect_uris: "redirect_uri must be a string"]
end
