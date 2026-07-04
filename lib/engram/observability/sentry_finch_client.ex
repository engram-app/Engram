defmodule Engram.Observability.SentryFinchClient do
  @moduledoc """
  Sentry HTTP client backed by Finch. Replaces Sentry's default hackney client
  so the backend carries no hackney dependency. Implements `Sentry.HTTPClient`:
  Sentry starts the named Finch pool via `child_spec/0` and calls `post/3` to
  ship events.
  """
  @behaviour Sentry.HTTPClient

  @impl true
  def child_spec do
    Supervisor.child_spec({Finch, name: __MODULE__}, id: __MODULE__)
  end

  @impl true
  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, __MODULE__) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
