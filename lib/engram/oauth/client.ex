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

  # CIMD accepts a DIFFERENT set, and the difference is not an oversight.
  #
  # `client_secret_*` needs a secret that only registration can mint, so it stays
  # refused for a client that never registered. `private_key_jwt` needs no minted
  # secret at all: the client signs an assertion with a key published at its own
  # `jwks_uri`, bound to the vendor's host by the same argument that binds the
  # document. DCR keeps refusing it — a stranger POSTing to /oauth/register has
  # no host-bound document to publish keys in.
  @cimd_auth_methods ~w(none private_key_jwt)
  @assertion_auth_methods ~w(private_key_jwt)
  @valid_grant_types ~w(authorization_code refresh_token)
  @valid_response_types ~w(code)
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)
  @client_name_max_length 200

  # Both bound row size; they answer to different threats.
  #
  # DCR is an anonymous POST, so the cap is anti-abuse and 10 is generous for a
  # real registrant. A CIMD document is bounded already — the fetcher caps the
  # body mid-stream — and belongs to a vendor supporting many surfaces at once.
  # MCPJam's published document lists 14 (three ports x several paths, plus app
  # and staging hosts) and is a perfectly ordinary client. Holding it to DCR's
  # number rejects it for being popular.
  @max_redirect_uris_dcr 10
  @max_redirect_uris_cimd 50

  schema "oauth_clients" do
    field :client_secret_hash, :string
    # Plaintext, returned in the registration response and never again. Virtual
    # so it cannot be persisted or read back: a client that loses its secret
    # re-registers.
    field :client_secret, :string, virtual: true, redact: true
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

    # Where a `private_key_jwt` client's signing keys live, copied off the
    # document so the token endpoint can verify an assertion without network I/O
    # on that path. NULL for every client that authenticates any other way.
    field :jwks_uri, :string
    field :token_endpoint_auth_signing_alg, :string

    # The document's full PERMITTED set, where `token_endpoint_auth_method` above
    # is only its preferred one. A vendor may declare `private_key_jwt` and still
    # authenticate as a public client when it also lists `none` — ChatGPT does
    # exactly that. Without this the preference was enforced as a requirement.
    #
    # NULL means "never read off a document" (a row predating this column) and is
    # not the same as `[]`, which means the document named nothing we support.
    field :token_endpoint_auth_methods_supported, {:array, :string}

    # Read-only metadata populated at DCR time.
    # Queries in Connections use :kind to distinguish MCP vs Obsidian clients.
    field :kind, :string, default: "mcp"
    field :first_user_agent, :string
    # DB column was changed from :inet to :text (migration 20260530000005).
    field :first_ip, :string

    timestamps(type: :utc_datetime_usec)
  end

  # `jwks_uri` and `token_endpoint_auth_signing_alg` are deliberately ABSENT.
  # DCR is an anonymous public POST, and casting them there would persist two
  # unbounded attacker-controlled strings that no DCR client can ever use (the
  # auth-method allowlist refuses `private_key_jwt` on that path). CIMD sets
  # them explicitly in `cimd_changeset/3`, where they came from a document
  # served by the vendor's own host.
  @cast_fields ~w(redirect_uris client_name scope grant_types response_types
                  token_endpoint_auth_method software_id software_version
                  logo_uri tos_uri policy_uri
                  kind first_user_agent first_ip)a

  @metadata_uri_fields ~w(logo_uri tos_uri policy_uri)a

  @doc "True when the registered auth method requires a client secret."
  @spec confidential?(String.t() | nil) :: boolean()
  def confidential?(method), do: method in @confidential_auth_methods

  @doc "The auth methods a CIMD document may declare (see `@cimd_auth_methods`)."
  def cimd_auth_methods, do: @cimd_auth_methods

  @doc """
  True when the client's own document permits authenticating with no credential.

  Read off `token_endpoint_auth_methods_supported`, never off the request. The
  set comes from a document served by the vendor's host, so honouring it is not
  the same as letting a caller choose its own method at token time — that is
  still refused, and is what keeps the registered method from being decorative.

  PKCE is mandatory on the exchange regardless (`check_pkce_verifier/2`), so a
  public-client exchange is still bound to the request that started it.

  NULL is deliberately `false`: a row written before the column existed never
  had the set read off its document, and widening on that absence would grant
  public auth to a client that may never have offered it.
  """
  def public_auth_permitted?(client), do: "none" in permitted_auth_methods(client)

  @doc """
  True when the client's own document permits authenticating with an assertion.

  The mirror of `public_auth_permitted?/1`, and it exists because the first fix
  for #1633 only corrected one direction. `assertion_based?/1` reads the
  PREFERRED method alone, so a document preferring `none` while also supporting
  `private_key_jwt` had its assertions refused as `:assertion_not_expected` —
  the same "preference treated as a requirement" mistake, pointing the other
  way. No vendor is known to publish that shape, which is precisely why it would
  have sat undiscovered until one did.
  """
  def assertion_permitted?(client) do
    Enum.any?(permitted_auth_methods(client), &(&1 in @assertion_auth_methods))
  end

  @doc """
  Every auth method the client's document allows, preferred one included.

  `token_endpoint_auth_method` is a PREFERENCE, not the only permitted value, so
  the effective set is the union of it and
  `token_endpoint_auth_methods_supported`. Deriving both predicates from one
  place is what stops the two halves drifting apart again.

  A row predating the supported-set column yields just `[preferred]`, so NULL
  still cannot widen anything — it reproduces the behaviour that row shipped
  with, and repopulates on the next document refetch.
  """
  def permitted_auth_methods(%__MODULE__{} = client) do
    supported = client.token_endpoint_auth_methods_supported || []

    [client.token_endpoint_auth_method | supported]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def permitted_auth_methods(_client), do: []

  @doc """
  `assertion_permitted?/1` for a RAW DOCUMENT, before any row exists.

  `Engram.OAuth.Cimd.validate_document/2` decides at authorize time whether a
  `jwks_uri` is required and fetchable. Those checks only make sense for a
  document that can present an assertion, and that question must be answered the
  SAME way here as it is at token time — otherwise a document passes validation
  and then cannot authenticate, which is the drift that produced #1640.

  Concretely: gating those checks on the preferred method alone let a document
  preferring `none` while supporting `private_key_jwt` skip both `jwks_uri`
  arms, persist an unvalidated URI, and turn every later exchange into a
  retried-forever 503 instead of a legible refusal at authorize.

  Rather than re-deriving the rule, this and `cimd_changeset/3` both read
  `document_permitted_auth_methods/1`. Agreement is structural rather than a
  coincidence of two lists that happen to match today: there is one permitted
  set, the changeset stores a member of it, and the row path unions that stored
  member back with the same stored set.

  That filter keeps `@cimd_auth_methods` only, so a method the CIMD path refuses
  cannot widen the answer, and an absent supported list maps to `[]` rather than
  `nil`: a document has always been READ, so it must not forge the NULL that
  means "this row predates the column".
  """
  def document_permits_assertion?(document) when is_map(document) do
    Enum.any?(document_permitted_auth_methods(document), &(&1 in @assertion_auth_methods))
  end

  def document_permits_assertion?(_document), do: false

  @doc """
  Every method a raw document permits that this path can actually honour.

  The union of the preferred method and the supported set, filtered to
  `@cimd_auth_methods`. One list now answers three questions that used to be
  asked separately and drifted apart: whether the document is connectable at all
  (`Engram.OAuth.Cimd.validate_document/2`), whether it may present an assertion
  (`document_permits_assertion?/1`), and which value `cimd_changeset/3` stores.

  EMPTY IS THE REFUSAL. A document whose every permitted method is secret-based
  has no flow left to run, because no secret was ever minted for a client that
  did not register. That is the only case `:confidential_not_supported` now
  covers, and narrowing it to that is the #1634 fix: the preferred method alone
  was read as a requirement, so a document naming `client_secret_basic` first
  was refused terminally even when it also permitted `private_key_jwt`.

  An absent preference maps to `none`, not to nothing. Omitting the field has
  always meant the public flow, and the permitted-set rule must not turn
  "unstated" into "unusable".
  """
  def document_permitted_auth_methods(document) when is_map(document) do
    preferred = document["token_endpoint_auth_method"] || "none"

    [preferred | supported_auth_methods(document)]
    |> Enum.filter(&(&1 in @cimd_auth_methods))
    |> Enum.uniq()
  end

  def document_permitted_auth_methods(_document), do: []

  # The value `cimd_changeset/3` stores in `token_endpoint_auth_method`.
  #
  # The document's own preference wins whenever we can honour it, so a vendor's
  # stated choice is never silently upgraded. Otherwise the strongest method it
  # DOES permit is stored, and `none` is never invented: a document permitting
  # only `private_key_jwt` must not yield a row claiming a public exchange was
  # allowed.
  #
  # With nothing usable the raw preference passes through to fail
  # `validate_inclusion`, keeping the changeset invalid. `validate_document/2`
  # refuses those documents earlier on the fetch path, so this is what stops a
  # direct caller inserting a client that could never authenticate.
  defp document_auth_method(document) do
    permitted = document_permitted_auth_methods(document)
    preferred = document["token_endpoint_auth_method"] || "none"

    cond do
      preferred in permitted -> preferred
      "private_key_jwt" in permitted -> "private_key_jwt"
      "none" in permitted -> "none"
      true -> document["token_endpoint_auth_method"]
    end
  end

  @doc """
  The grant and response types this authorization server actually implements.

  Exposed for `Engram.OAuth.Cimd`, which INTERSECTS a fetched document against
  these rather than refusing a client for declaring more than we do. DCR keeps
  using them as a `validate_subset` allowlist — a registration request is a
  stranger asking our permission, a published metadata document is a vendor
  describing itself to every authorization server in the world. Same lists, two
  different questions; the lists live here so the two answers cannot drift.
  """
  @spec supported_grant_types() :: [String.t()]
  def supported_grant_types, do: @valid_grant_types

  @spec supported_response_types() :: [String.t()]
  def supported_response_types, do: @valid_response_types

  @doc "The optional RFC 7591 §2 metadata URIs, and the cap on `client_name`."
  # No @spec on either: both return a compile-time constant, so any spec loose
  # enough to be worth writing is a supertype of the success typing and dialyzer
  # rejects it, while a spec tight enough to pass just restates the literal.
  def metadata_uri_fields, do: @metadata_uri_fields

  def client_name_max_length, do: @client_name_max_length

  @doc """
  True when an optional metadata URI is one we would actually render.

  Shares `parse_https_uri/1` with `validate_metadata_uris/1` so the rule has one
  implementation. DCR rejects a bad value (the registrant can fix it and retry);
  CIMD drops it, because losing a logo must never cost a vendor its connector.
  """
  @spec displayable_metadata_uri?(term()) :: boolean()
  def displayable_metadata_uri?(value), do: parse_https_uri(value) == :ok

  @doc """
  True for the loopback hosts RFC 8252 §7.3 permits over plain `http`.

  Shared with `Engram.OAuth.match_redirect_uri/2`, which grants those hosts a
  port exemption at authorization time. Registration and authorization must
  agree on what counts as loopback: if this list drifted between them, a URI
  could be accepted at DCR and then rejected on every authorize.
  """
  @spec loopback_host?(String.t() | nil) :: boolean()
  def loopback_host?(host), do: host in @loopback_hosts

  def registration_changeset(client, attrs, opts \\ []) do
    client
    |> cast(attrs, @cast_fields)
    |> coerce_kind()
    |> apply_defaults()
    |> ensure_redirect_uris_present()
    # Attacker-controlled on a public, unauthenticated endpoint; bound the
    # array size so registration can't be used to store an unbounded blob.
    |> validate_length(:redirect_uris,
      max: Keyword.get(opts, :max_redirect_uris, @max_redirect_uris_dcr)
    )
    |> validate_redirect_uris()
    |> validate_subset(:grant_types, @valid_grant_types,
      message: "contains an unsupported grant_type"
    )
    |> validate_subset(:response_types, @valid_response_types,
      message: "contains an unsupported response_type"
    )
    |> validate_auth_method(Keyword.get(opts, :auth_methods, @valid_auth_methods))
    |> validate_length(:client_name, max: @client_name_max_length)
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

    * `token_endpoint_auth_method` is a method the document PERMITS, not
      necessarily the one it prefers. The preference wins when we can honour it;
      otherwise the strongest method the document also permits is stored (see
      `document_permitted_auth_methods/1`). A document permitting nothing but
      secret-based methods is refused by the caller rather than downgraded,
      because no secret was ever minted for a client that did not register (see
      `Engram.OAuth.Cimd`). `private_key_jwt` carries `jwks_uri` across with it.
    * `software_id` is dropped. It would be attributable here — the document is
      served by the vendor's own host — but it buys nothing: after #1156 the
      `software_id` map names only our own plugin. Storing it would re-grow the
      surface that issue removed.
  """
  def cimd_changeset(client, url, document) when is_binary(url) and is_map(document) do
    client
    |> registration_changeset(
      %{
        "redirect_uris" => document["redirect_uris"],
        "client_name" => document["client_name"],
        "scope" => document["scope"],
        "grant_types" => document["grant_types"],
        "response_types" => document["response_types"],
        "logo_uri" => document["logo_uri"],
        "tos_uri" => document["tos_uri"],
        "policy_uri" => document["policy_uri"],
        "kind" => "mcp",
        "token_endpoint_auth_method" => document_auth_method(document)
      },
      max_redirect_uris: @max_redirect_uris_cimd,
      auth_methods: @cimd_auth_methods
    )
    # Only stored when the document can actually authenticate with one. A
    # `jwks_uri` on a document that permits no assertion method is unusable
    # decoration, and the policy for unusable optional metadata is already
    # settled directly above for `logo_uri`: DROP it, never refuse the client
    # over it, because losing decoration must not cost a vendor its connector.
    #
    # Bounding its length instead was the wrong shape. It refused the whole
    # client over a field that client could not use, and it capped size rather
    # than junk — `"not-a-url::%%"` was still accepted and stored verbatim.
    # Not storing it removes the unbounded-string concern entirely and keeps the
    # validated-on-use invariant: a persisted `jwks_uri` has always been through
    # `displayable_metadata_uri?/1` and `SsrfGuard.validate_url/1` at authorize.
    |> put_change(:jwks_uri, usable_jwks_uri(document))
    |> put_change(:token_endpoint_auth_signing_alg, document["token_endpoint_auth_signing_alg"])
    |> put_change(:token_endpoint_auth_methods_supported, supported_auth_methods(document))
    |> put_change(:cimd_url, url)
    |> put_change(:cimd_fetched_at, DateTime.utc_now())
    |> validate_length(:cimd_url, max: 2048)
    # Converts the partial unique index into a changeset error so a concurrent
    # first-contact race resolves by re-reading the winner's row instead of
    # raising. Named explicitly: the index is partial, so Ecto cannot infer it.
    |> unique_constraint(:cimd_url, name: :oauth_clients_cimd_url_index)
  end

  # Only methods we can actually honour are stored. A document is free to
  # advertise `client_secret_basic`; persisting it would record a permission the
  # CIMD path refuses anyway, and a later reader would have to re-derive which
  # entries were real.
  #
  # An absent list becomes `[]`, not NULL: the document WAS read and named
  # nothing usable, which is a different fact from a row that predates the
  # column. Only the latter may not be widened. A document declaring
  # `private_key_jwt` and no supported set therefore keeps requiring an
  # assertion, which is the strictest reading of what it offered.
  # NULL unless the document permits an assertion method. Paired with the two
  # `validate_document/2` arms that run for exactly the same predicate, this
  # makes a stored `jwks_uri` mean "already validated", and clears a stale one
  # on refresh if a vendor narrows its permitted set.
  defp usable_jwks_uri(document) do
    if document_permits_assertion?(document), do: document["jwks_uri"]
  end

  defp supported_auth_methods(document) do
    case document["token_endpoint_auth_methods_supported"] do
      methods when is_list(methods) -> Enum.filter(methods, &(&1 in @cimd_auth_methods))
      _absent -> []
    end
  end

  # DCR is a public endpoint:
  #   - "mcp" passes through.
  #   - "obsidian" is rejected: revoke routing in the Connections UI assumes
  #     all Obsidian grants are device-flow today. Until a DCR-minted Obsidian
  #     client has an `auth_path` discriminator, accepting one would silently
  #     break the revoke button.
  #   - Anything else: log + default to "mcp" so legitimate typos aren't
  #     hostile UX, but we can grep the logs for "kind drift" later.
  # The allowlist is a parameter rather than a constant because DCR and CIMD ask
  # different questions of the same field. Passing it in keeps ONE changeset
  # rather than growing a second, drift-prone CIMD validation path — the mistake
  # that caused the 2026-08-04 outage, in the opposite direction.
  defp validate_auth_method(changeset, allowed) do
    validate_inclusion(changeset, :token_endpoint_auth_method, allowed,
      message: "must be one of: #{Enum.join(allowed, ", ")}"
    )
  end

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
