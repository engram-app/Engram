defmodule Engram.Analytics.McpClient do
  @moduledoc """
  Buckets an MCP / OAuth client into a known family for analytics props.

  Input is client-supplied text (a `clientInfo.name`, a user agent, a DCR
  `client_name`) or a CIMD host. Output is one of a fixed set, so nothing
  attacker-chosen ever becomes a PostHog property value. Matched against the
  lowercased text; order matters ("claude-code" before "claude").
  """

  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Client

  @families [
    {"claude-code", "claude-code"},
    {"claude", "claude"},
    {"anthropic", "claude"},
    {"chatgpt", "chatgpt"},
    {"openai", "chatgpt"},
    {"cursor", "cursor"},
    {"windsurf", "windsurf"},
    {"vscode", "vscode"},
    {"visual studio code", "vscode"},
    {"cline", "cline"},
    {"zed", "zed"},
    {"goose", "goose"}
  ]

  @doc "The family `text` names, or \"other\"."
  @spec family(term()) :: String.t()
  def family(text) when is_binary(text) do
    text = text |> String.slice(0, 256) |> String.downcase()

    Enum.find_value(@families, "other", fn {needle, family} ->
      if String.contains?(text, needle), do: family
    end)
  end

  def family(_text), do: "other"

  @known_scopes ~w(mcp offline_access openid profile email)

  @doc """
  Scope names as analytics labels: the common ones by name, anything else as
  "other" (a requested scope is free text from the client).
  """
  @spec scope_labels([String.t()] | String.t()) :: [String.t()]
  def scope_labels(scope) when is_binary(scope),
    do: scope |> String.split(" ", trim: true) |> scope_labels()

  def scope_labels(scopes) when is_list(scopes),
    do: Enum.map(scopes, &if(&1 in @known_scopes, do: &1, else: "other"))

  @doc """
  The props every OAuth funnel event carries about its client.
  """
  @spec client_props(Client.t() | nil) :: map()
  def client_props(client) do
    {family, registration} = of_client(client)
    %{client: family, registration: registration}
  end

  @doc """
  `{family, registration}` for a stored OAuth client: a CIMD client by its
  document's host, a DCR client by its `client_name`.
  """
  @spec of_client(Client.t() | nil) :: {String.t(), String.t() | nil}
  def of_client(%Client{cimd_url: url}) when is_binary(url),
    do: {family(Cimd.host_of(url)), "cimd"}

  def of_client(%Client{client_name: name}), do: {family(name), "dcr"}
  def of_client(_client), do: {"other", nil}
end
