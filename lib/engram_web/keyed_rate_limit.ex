defmodule EngramWeb.KeyedRateLimit do
  @moduledoc """
  Shared core of the limiters whose bucket depends on the route: a per-path
  policy, a hashed credential in the key, then a coarse per-IP ceiling. The
  plugs around it (`EngramWeb.Plugs.OAuthRateLimit`,
  `EngramWeb.Plugs.DeviceAuthRateLimit`) own only their policy map, where the
  credential comes from, and the shape of the refusal.

  Policy entries are `{kind, limit_per_minute}`:

    * `:ip`: per IP. For a route with no credential to key on.
    * `:client`: per credential PER IP. For a PUBLIC identifier: a CIMD
      `client_id` is a URL shared by every user of a vendor, so a bucket keyed
      on it alone would let anyone exhaust that vendor.
    * `:secret`: per credential alone. For an unguessable value only its
      holder can send, so people sharing one network address never share a
      bucket and no stranger can spend it.

  `:client` and `:secret` fall back to a per-IP anonymous bucket when the
  request carries no credential, and also draw from a #{3_000}/min per-IP
  ceiling so a caller cannot dodge the limit by inventing credentials. Only
  requests the primary bucket allowed count against the ceiling: a flood it
  refused must not drain what everyone else on that IP shares.

  Credentials are attacker-supplied, so they are hashed into the key (bounded
  length) and neither stored raw nor logged.

  Overrides: test builds read `:rate_limit_override` (primary bucket) and
  `:oauth_ip_rate_limit_override` (ceiling); other builds read
  `:rate_limit_auth_override` for both (CI containers).
  """

  @period_ms 60_000
  @ip_coarse_limit 3_000

  @is_test_build Application.compile_env(:engram, :env, :prod) == :test

  @type kind :: :ip | :client | :secret
  @type config :: %{
          optional(:route) => ([String.t()] -> [String.t()]),
          policy: %{String.t() => {kind(), pos_integer()}},
          default: {kind(), pos_integer()},
          prefix: String.t(),
          purpose: EngramWeb.RateLimiter.purpose(),
          credential: (Plug.Conn.t() -> String.t() | nil)
        }

  @spec check(Plug.Conn.t(), config()) :: :ok | {:deny, String.t(), non_neg_integer()}
  def check(conn, config) do
    # The ROUTED path: `/oauth/token/` reaches the same action as
    # `/oauth/token`, so it must draw from the same bucket. `:route` folds a
    # path with a parameter in it onto one policy entry.
    path = "/" <> Enum.join(Map.get(config, :route, & &1).(conn.path_info), "/")
    {kind, limit} = Map.get(config.policy, path, config.default)
    ip = client_ip(conn)

    with :ok <- hit(primary_key(kind, conn, path, ip, config), effective_limit(limit), config),
         :ok <- coarse_ip(kind, path, ip, config) do
      :ok
    else
      {:deny, retry_after_ms} -> {:deny, path, retry_after_ms}
    end
  end

  @doc "The caller's real IP as a string (`EngramWeb.RemoteIp`, never raw x-forwarded-for)."
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn), do: conn |> EngramWeb.RemoteIp.resolve() |> :inet.ntoa() |> to_string()

  defp coarse_ip(:ip, _path, _ip, _config), do: :ok

  defp coarse_ip(_kind, path, ip, config),
    do: hit("#{config.prefix}:ip:#{path}:#{ip}", coarse_limit(), config)

  defp primary_key(:ip, _conn, path, ip, config), do: "#{config.prefix}:ip:#{path}:#{ip}"

  defp primary_key(kind, conn, path, ip, config) do
    case {config.credential.(conn), kind} do
      {nil, _kind} -> "#{config.prefix}:ip:#{path}:#{ip}:anon"
      {id, :client} -> "#{config.prefix}:client:#{path}:#{digest(id)}:#{ip}"
      {id, :secret} -> "#{config.prefix}:secret:#{path}:#{digest(id)}"
    end
  end

  defp digest(id), do: :crypto.hash(:sha256, id) |> Base.url_encode64(padding: false)

  defp hit(key, limit, config) do
    case EngramWeb.RateLimiter.hit(key, @period_ms, limit, config.purpose) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  # Compile-time branch, so `:rate_limit_override` is structurally impossible
  # in a non-test build.
  if @is_test_build do
    @doc "`default`, unless a test or CI override replaces it."
    def effective_limit(default),
      do: Application.get_env(:engram, :rate_limit_override) || default

    defp coarse_limit,
      do: Application.get_env(:engram, :oauth_ip_rate_limit_override) || @ip_coarse_limit
  else
    @doc "`default`, unless a test or CI override replaces it."
    def effective_limit(default),
      do: Application.get_env(:engram, :rate_limit_auth_override) || default

    defp coarse_limit,
      do: Application.get_env(:engram, :rate_limit_auth_override) || @ip_coarse_limit
  end
end
