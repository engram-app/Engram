defmodule Engram.Instance.SetupToken do
  @moduledoc """
  One-time setup token that gates the self-host first-run admin claim.

  While `Engram.Instance.bootstrap_pending?/0` is true, the first successful
  `POST /api/auth/register` becomes the instance admin. Without a gate, a freshly
  deployed, internet-reachable instance belongs to whoever finds it first. So,
  like Jenkins and Grafana:

    * `boot/0` (run once per boot, local auth only) mints a random token while
      bootstrap is pending, stores ONLY its SHA-256 in the `instance_setup_token`
      singleton row, and prints the raw token on one boot log line. Every boot
      rotates it, so the newest log line holds the valid one.
    * `valid?/1` is what the register controller checks during the claim window.
    * `burn/0` runs inside the claim transaction (`Accounts.create_user_with_password/2`)
      so the row is gone the moment the admin exists.

  `ENGRAM_SETUP_TOKEN` (`config :engram, :setup_token`) replaces the random
  token with a fixed one, for CI, e2e stacks and local dev. Its value is never
  logged. It only matters while bootstrap is pending.

  Fails closed: no row (boot hook never ran, or the table is missing) means
  every token is invalid and the claim is refused with 403.

  The raw token is deliberately in the boot line's MESSAGE, the one place it
  appears. It never travels as metadata, and nothing else here logs it.
  See `docs/context/self-host-setup-token.md`.
  """
  import Ecto.Query, only: [from: 2]

  alias Engram.Instance
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  # Same sentinel as the other instance singletons (`Engram.Instance`).
  @singleton_id "00000000-0000-0000-0000-000000000000"

  # 24 random bytes -> 32 url-safe chars: copy-pasteable, ~192 bits.
  @token_bytes 24

  defmodule Row do
    @moduledoc false
    use Engram.Schema

    schema "instance_setup_token" do
      field :token_hash, :string
      timestamps(type: :utc_datetime)
    end
  end

  @doc """
  Boot hook. Mints (or rotates) the token while bootstrap is pending and logs it
  once; deletes any leftover row otherwise. Never raises: a failure here must not
  stop the node, and the claim simply stays refused until a boot succeeds.
  """
  def boot do
    if Engram.Auth.supports_credentials?() do
      if Instance.bootstrap_pending?() do
        configured = configured_token()
        {:ok, raw} = mint(configured || generate())
        log_token(raw, configured != nil)
      else
        burn()
      end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "setup token: could not mint the first-run setup token; " <>
          "registering the admin will be refused until the next boot succeeds",
        Metadata.with_category(:warning, :boot, reason: Metadata.safe_reason(e))
      )

      :ok
  end

  @doc """
  Stores the hash of `raw`, replacing any previous token. Returns `{:ok, raw}`.
  Public so tests can mint a known token through the same path as boot.
  """
  def mint(raw) when is_binary(raw) and raw != "" do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.insert(
        %Row{id: @singleton_id, token_hash: hash(raw), inserted_at: now, updated_at: now},
        on_conflict: [set: [token_hash: hash(raw), updated_at: now]],
        conflict_target: :id,
        skip_tenant_check: true
      )

    {:ok, raw}
  end

  @doc "True when `candidate` matches the stored token. Constant-time compare."
  def valid?(candidate) when is_binary(candidate) do
    candidate = String.trim(candidate)

    case Repo.get(Row, @singleton_id, skip_tenant_check: true) do
      %Row{token_hash: stored} when candidate != "" ->
        Plug.Crypto.secure_compare(hash(candidate), stored)

      _ ->
        false
    end
  end

  def valid?(_), do: false

  @doc "Deletes the token. Called inside the claim transaction. Idempotent."
  def burn do
    _ =
      Repo.delete_all(
        from(r in Row, where: r.id == ^@singleton_id),
        skip_tenant_check: true
      )

    :ok
  end

  defp generate,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp hash(raw), do: Engram.Crypto.sha256_hex(raw)

  defp configured_token do
    case Application.get_env(:engram, :setup_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  # :info under :boot, so it reaches the operator's log but never Sentry
  # (warning/error only). Static text plus the token, nothing else.
  defp log_token(_raw, true = _from_env) do
    Logger.info(
      "Engram first-run setup: no admin account exists yet. Create it in the web app " <>
        "using the setup token from ENGRAM_SETUP_TOKEN.",
      Metadata.with_category(:info, :boot, [])
    )
  end

  defp log_token(raw, false) do
    Logger.info(
      "Engram first-run setup: no admin account exists yet. Open the web app and enter " <>
        "this one-time setup token to create it: #{raw} " <>
        "(a new token is printed on every restart until the admin account exists)",
      Metadata.with_category(:info, :boot, [])
    )
  end
end
