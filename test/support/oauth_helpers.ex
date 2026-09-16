defmodule Engram.OAuthHelpers do
  @moduledoc """
  PKCE and authorization-code helpers shared across the OAuth test files.

  These two exist because they had been copy-pasted five (`pkce_pair/0`) and
  seven (`code_from_redirect/1`) times, in four different spellings apiece,
  with no behavioural difference between any of the copies.

  Client-registration helpers deliberately stay per-file. They go through
  `OAuth.register_client/1`, which the `oauth_client_factory` cannot stand in
  for because the factory never mints a `client_secret`.
  """

  @doc "Returns `{verifier, challenge}`: a 48-byte verifier and its S256 challenge."
  @spec pkce_pair() :: {String.t(), String.t()}
  def pkce_pair do
    verifier = 48 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  @doc "Pulls the `code` query param out of an authorization redirect URL."
  @spec code_from_redirect(String.t()) :: String.t()
  def code_from_redirect(redirect_url) do
    redirect_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("code")
  end
end
