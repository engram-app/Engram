defmodule Engram.PromEx.OAuth do
  @moduledoc """
  PromEx plugin for the OAuth token endpoint (#1974).

    * `[:engram, :oauth, :token]` → `engram_prom_ex_oauth_token_total`, tags
      `[:grant_type, :result, :reason, :client, :client_agent]`. Emitted once
      per `/oauth/token` request by `EngramWeb.OAuthTokenController`.

    * `[:engram, :oauth, :consent]` → `engram_prom_ex_oauth_consent_total`, tags
      `[:client, :device]`, one per code minted at consent
      (`EngramWeb.OAuthAuthorizeController.consent/2`). Divided into the token
      counter's `grant_type="authorization_code", result="issued"` per client it
      is the redemption ratio: a consent page that never hands back to the
      client shows as mints with no exchanges.

    * `[:engram, :oauth, :code_expired]` →
      `engram_prom_ex_oauth_code_expired_total`, tag `[:client]`, one
      per code reaped unredeemed by `Engram.OAuth.cleanup_expired/0` (hourly,
      so it lags expiry by up to two hours).

  Every tag is a closed atom set:

    * `grant_type`: `:authorization_code | :refresh_token | :other | :missing`
    * `result`: `:issued | :rejected`
    * `client`: the `Engram.Analytics.McpClient` family (a fixed string set,
      `"other"` for anything unknown)
    * `client_agent`: `McpClient.agent/2`, `"codex"` / `"chatgpt"` by the token
      request's User-Agent, else the `client` family
    * `device`: `Engram.Analytics.Device`, `"mobile" | "desktop" | "unknown"`
    * `reason`: `:none` on success; otherwise an `Engram.OAuth.grant_reason()`
      or one of the controller's own: `:refresh_token_missing`,
      `:unsupported_grant_type`, `:grant_type_missing`, `:token_persist_failed`,
      `:client_auth_failed`, `:client_auth_unavailable`.

    * `[:engram, :cimd, :fetch]` → `engram_prom_ex_cimd_fetch_total`, tags
      `[:kind, :result, :reason]`.
      `kind` is `:jwks | :doc`; `result` is `:ok | :stale | :error` (stale =
      the fetch failed and held keys were served: warn; error = nothing
      usable: page); `reason` is `Engram.OAuth.Cimd.emit_fetch/4`'s closed
      label set.

    * `[:engram, :cimd, :assertion_audience]` →
      `engram_prom_ex_cimd_assertion_audience_total`, tags `[:aud_form, :client]`,
      one per `private_key_jwt` assertion checked: `aud_form` is
      `Engram.OAuth.Cimd.Jwks.aud_form()`, `client` the bounded
      `Engram.Analytics.McpClient.host_family/1` of the CIMD host (exact match).

  Cardinality contract: `client` is only ever a family label; never the client
  id, host or user agent. Those live on
  the `oauth_token_rejected` / `mcp_cimd_fetch_failed` log lines.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :oauth)
    cimd_prefix = PromEx.metric_prefix(otp_app, :cimd)

    Event.build(
      :engram_oauth_event_metrics,
      [
        counter(
          metric_prefix ++ [:token, :total],
          event_name: [:engram, :oauth, :token],
          description: "OAuth token-endpoint outcomes by grant type, result and reason.",
          tags: [:grant_type, :result, :reason, :client, :client_agent]
        ),
        counter(
          metric_prefix ++ [:consent, :total],
          event_name: [:engram, :oauth, :consent],
          description: "Authorization codes minted at consent, per client family and device.",
          tags: [:client, :device]
        ),
        counter(
          metric_prefix ++ [:code_expired, :total],
          event_name: [:engram, :oauth, :code_expired],
          description: "Authorization codes that expired without being exchanged.",
          tags: [:client]
        ),
        counter(
          cimd_prefix ++ [:fetch, :total],
          event_name: [:engram, :cimd, :fetch],
          description: "CIMD document and JWKS fetches by kind, result and reason.",
          tags: [:kind, :result, :reason]
        ),
        counter(
          cimd_prefix ++ [:assertion_audience, :total],
          event_name: [:engram, :cimd, :assertion_audience],
          description:
            "private_key_jwt assertions by which of our audiences aud named, per client.",
          tags: [:aud_form, :client]
        )
      ]
    )
  end
end
