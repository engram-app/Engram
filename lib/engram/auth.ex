defmodule Engram.Auth do
  @moduledoc "Auth provider dispatch. Reads :auth_provider config to select the active provider."

  def provider do
    case Application.get_env(:engram, :auth_provider, :local) do
      :local -> Engram.Auth.Providers.Local
      :clerk -> Engram.Auth.Providers.Clerk
      other -> raise "Invalid :auth_provider config: #{inspect(other)}. Must be :local or :clerk"
    end
  end

  def supports_credentials?, do: provider().supports_credentials?()

  @doc """
  Bounded, low-cardinality label for an auth-rejection reason — safe as a
  telemetry tag and a log value.

  TokenResolver returns either a bare atom (`:no_auth`, `:missing_claims`,
  `:invalid_azp`, ...) or a Joken claim-validation keyword list. The Joken
  message is free text, so it is dropped here — only the claim name escapes,
  keeping the tag space bounded.
  """
  def rejection_label(reason) when is_list(reason) do
    case Keyword.get(reason, :claim) do
      nil -> "invalid_token"
      claim -> "claim_invalid:#{claim}"
    end
  end

  def rejection_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  def rejection_label(_), do: "other"

  @doc """
  Emit `[:engram, :auth, :rejected]` tagged by a bounded reason + source
  (`:http` | `:socket`) and return the label. One alertable time series for
  every auth failure across the HTTP plug and the WebSocket connect path —
  previously only the plug logged (at `:info`) and the socket was silent.
  """
  def emit_rejected(reason, source) when is_atom(source) do
    label = rejection_label(reason)
    :telemetry.execute([:engram, :auth, :rejected], %{count: 1}, %{reason: label, source: source})
    label
  end
end
