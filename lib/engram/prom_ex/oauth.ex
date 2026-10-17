defmodule Engram.PromEx.OAuth do
  @moduledoc """
  PromEx plugin for the OAuth token endpoint (#1974).

    * `[:engram, :oauth, :token]` → `engram_prom_ex_oauth_token_total`, tags
      `[:grant_type, :result, :reason]`. Emitted once per `/oauth/token`
      request by `EngramWeb.OAuthTokenController`.

  Every tag is a closed atom set:

    * `grant_type`: `:authorization_code | :refresh_token | :other | :missing`
    * `result`: `:issued | :rejected`
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

  Cardinality contract: never the client id, host or user agent. Those live on
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
          tags: [:grant_type, :result, :reason]
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
