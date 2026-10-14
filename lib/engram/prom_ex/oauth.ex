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

  Cardinality contract: never the client id, host or user agent. Those live on
  the `oauth_token_rejected` log line.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :oauth)

    Event.build(
      :engram_oauth_event_metrics,
      [
        counter(
          metric_prefix ++ [:token, :total],
          event_name: [:engram, :oauth, :token],
          description: "OAuth token-endpoint outcomes by grant type, result and reason.",
          tags: [:grant_type, :result, :reason]
        )
      ]
    )
  end
end
