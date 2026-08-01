defmodule Engram.OAuth.Client do
  @moduledoc """
  Schema for an OAuth 2.1 client registered via Dynamic Client Registration
  (RFC 7591).

  Public clients (PKCE-only) carry no secret. Confidential clients
  (`client_secret_post` / `client_secret_basic`) are minted a secret at
  registration and authenticate at the token endpoint; server-side connectors
  such as LobeHub cloud require one. PKCE is mandatory for both.
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  @type t :: %__MODULE__{}

  @primary_key {:client_id, :binary_id, autogenerate: true}
  # Public PKCE clients (`none`) and confidential clients. A confidential
  # registration mints a secret in `Engram.OAuth.register_client/1`, so the 201
  # always carries one; the earlier restriction to `none` existed only because
  # nothing minted secrets, and it made server-side connectors (LobeHub cloud)
  # unregisterable rather than merely unverified.
  #
  # PKCE stays mandatory for BOTH. A secret authenticates the client; PKCE binds
  # the code to the request that started it. They are not substitutes.
  @valid_auth_methods ~w(none client_secret_post client_secret_basic)
  @confidential_auth_methods ~w(client_secret_post client_secret_basic)
  @valid_grant_types ~w(authorization_code refresh_token)
  @valid_response_types ~w(code)
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  schema "oauth_clients" do
    field :client_secret_hash, :string
    # Plaintext, returned in the registration response and never again. Virtual
    # so it cannot be persisted or read back: a client that loses its secret
    # re-registers.
    field :client_secret, :string, virtual: true
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

    # CIMD (Client ID Metadata Documents). `cimd_url` is the wire `client_id` for
    # a client that published a metadata document instead of registering: an
    # HTTPS URL its vendor owns. NULL for every DCR client. The UUID primary key
    # stays the internal identity either way (see `Engram.OAuth.get_client/1`).
    #
    # `cimd_fetched_at` is the cache clock — the row is the document cache, so
    # there is no second source of truth for the redirect allowlist derived from
    # it.
    field :cimd_url, :string
    field :cimd_fetched_at, :utc_datetime_usec

    # Read-only metadata populated at DCR time.
    # Queries in Connections use :kind to distinguish MCP vs Obsidian clients.
    field :kind, :string, default: "mcp"
    field :first_user_agent, :string
    # DB column was changed from :inet to :text (migration 20260530000005).
    field :first_ip, :string

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(redirect_uris client_name scope grant_types response_types
                  token_endpoint_auth_method software_id software_version
                  logo_uri tos_uri policy_uri
                  kind first_user_agent first_ip)a

  @metadata_uri_fields ~w(logo_uri tos_uri policy_uri)a

  @doc "True when the registered auth method requires a client secret."
  @spec confidential?(String.t() | nil) :: boolean()
  def confidential?(method), do: method in @confidential_auth_methods

  @doc """
  True for the loopback hosts RFC 8252 §7.3 permits over plain `http`.

  Shared with `Engram.OAuth.match_redirect_uri/2`, which grants those hosts a
  port exemption at authorization time. Registration and authorization must
  agree on what counts as loopback: if this list drifted between them, a URI
  could be accepted at DCR and then rejected on every authorize.
  """
  @spec loopback_host?(String.t() | nil) :: boolean()
  def loopback_host?(host), do: host in @loopback_hosts

  def registration_changeset(client, attrs) do
    client
    |> cast(attrs, @cast_fields)
    |> coerce_kind()
    |> apply_defaults()
    |> ensure_redirect_uris_present()
    # Attacker-controlled on a public, unauthenticated endpoint; bound the
    # array size so registration can't be used to store an unbounded blob.
    |> validate_length(:redirect_uris, max: 10)
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
    # Attacker-controlled on a public, unauthenticated endpoint; cap to bound
    # row/metadata size.
    |> validate_length(:software_id, max: 255)
    |> validate_length(:software_version, max: 255)
    |> validate_length(:first_user_agent, max: 500)
    |> validate_metadata_uris()
  end

  @doc """
  Changeset for a client whose metadata came from a CIMD document rather than a
  DCR request body.

  Deliberately routed through `registration_changeset/2`: a metadata document
  carries the same RFC 7591 fields, and every validation there (redirect-URI
  schemes, the `https:///cb` host-less trap, array bounds, grant/response type
  subsets, metadata URI schemes) applies verbatim. A CIMD-specific validation
  path would be a second implementation of the same rules, free to drift.

  Two fields are NOT taken from the document:

    * `token_endpoint_auth_method` is forced to `none`. A CIMD client never
      registered, so no secret was ever minted for it; PKCE is the binding. The
      caller rejects a document that asks for a confidential method rather than
      silently downgrading it (see `Engram.OAuth.Cimd`).
    * `software_id` is dropped. It would be attributable here — the document is
      served by the vendor's own host — but it buys nothing: after #1156 the
      `software_id` map names only our own plugin. Storing it would re-grow the
      surface that issue removed.
  """
  def cimd_changeset(client, url, document) when is_binary(url) and is_map(document) do
    client
    |> registration_changeset(%{
      "redirect_uris" => document["redirect_uris"],
      "client_name" => document["client_name"],
      "scope" => document["scope"],
      "grant_types" => document["grant_types"],
      "response_types" => document["response_types"],
      "logo_uri" => document["logo_uri"],
      "tos_uri" => document["tos_uri"],
      "policy_uri" => document["policy_uri"],
      "kind" => "mcp",
      "token_endpoint_auth_method" => "none"
    })
    |> put_change(:cimd_url, url)
    |> put_change(:cimd_fetched_at, DateTime.utc_now())
    |> validate_length(:cimd_url, max: 2048)
    # Converts the partial unique index into a changeset error so a concurrent
    # first-contact race resolves by re-reading the winner's row instead of
    # raising. Named explicitly: the index is partial, so Ecto cannot infer it.
    |> unique_constraint(:cimd_url, name: :oauth_clients_cimd_url_index)
  end

  # DCR is a public endpoint:
  #   - "mcp" passes through.
  #   - "obsidian" is rejected: revoke routing in the Connections UI assumes
  #     all Obsidian grants are device-flow today. Until a DCR-minted Obsidian
  #     client has an `auth_path` discriminator, accepting one would silently
  #     break the revoke button.
  #   - Anything else: log + default to "mcp" so legitimate typos aren't
  #     hostile UX, but we can grep the logs for "kind drift" later.
  defp coerce_kind(changeset) do
    case get_field(changeset, :kind) do
      "mcp" ->
        changeset

      "obsidian" ->
        add_error(changeset, :kind, "obsidian clients must use the device flow")

      other ->
        Logger.debug(
          "DCR: unknown kind; defaulting to mcp",
          Engram.Logger.Metadata.with_category(:debug, :auth, kind: inspect(other))
        )

        put_change(changeset, :kind, "mcp")
    end
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

  defp check_uri(uri) when is_binary(uri) and byte_size(uri) > 2048 do
    [redirect_uris: "redirect_uri too long"]
  end

  defp check_uri(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: nil}} ->
        [redirect_uris: "missing scheme: #{uri}"]

      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        []

      # `https:///cb` and `https:foo` parse with scheme "https" and a nil/empty
      # host, so they miss the clause above. Without this they would reach the
      # permissive custom-scheme branch and be admitted as if "https" were a
      # native-app scheme. Admitting custom schemes must not silently admit a
      # well-known scheme with its host missing.
      {:ok, %URI{scheme: "https"}} ->
        [redirect_uris: "missing host: #{uri}"]

      {:ok, %URI{scheme: "http", host: host}} ->
        if loopback_host?(host),
          do: [],
          else: [redirect_uris: "non-loopback http is not allowed: #{uri}"]

      {:ok, %URI{scheme: scheme}} when scheme in ["javascript", "data", "file"] ->
        [redirect_uris: "unsafe scheme #{scheme}: #{uri}"]

      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" ->
        # Native-app custom scheme (`cursor://…`, `com.cursor.app://…`).
        #
        # We previously required a reverse-DNS dot in the scheme, citing
        # RFC 8252 §7.1. That section obliges *apps* to choose such a scheme;
        # it does not ask authorization servers to reject the ones that don't,
        # and enforcing it turned real clients away at registration (observed
        # 2026-07-30: Cursor desktop registers `cursor://`).
        #
        # The dot bought less than it looked like. It never made a scheme
        # exclusive: any app can claim `com.foo://` as easily as `foo://`, so it
        # lowered accidental-collision odds, not deliberate squatting.
        # The real defence against a squatter intercepting the redirect is
        # PKCE, which RFC 8252 mandates for exactly this reason and which we
        # require unconditionally: an interceptor gets a code it cannot
        # redeem without the verifier.
        #
        # Custom schemes remain permanently unverifiable (see
        # Connections.LogoAllowlist). This admits them; it does not trust them.
        []

      _ ->
        [redirect_uris: "invalid URI: #{uri}"]
    end
  end

  defp check_uri(_), do: [redirect_uris: "redirect_uri must be a string"]
end
