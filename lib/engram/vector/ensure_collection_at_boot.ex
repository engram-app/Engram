defmodule Engram.Vector.EnsureCollectionAtBoot do
  @moduledoc """
  Ensures the notes collection and its payload indexes, for this boot's flag
  state, once per node at boot (`Engram.Indexing.ensure_collection/0`).

  Without it the indexes appeared only when the node first indexed a note. A
  deploy that turns the v5 flags on (and a dry run, which never indexes)
  left search and the reconcile filtering on `u` and the other v5 keys that
  strict mode refuses unindexed.

  Runs after `init/1` returns, so boot never waits on Qdrant. Idempotent and
  safe on many nodes at once: an index that exists is skipped, and a
  concurrent create of the same index is a 200. A failure (Qdrant down) is
  logged and retried every `retry_ms`; the process stops once it succeeds.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Engram.Logger.Metadata

  @retry_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, Keyword.get(opts, :retry_ms, @retry_ms), {:continue, :ensure}}

  @impl true
  def handle_continue(:ensure, retry_ms), do: ensure(retry_ms)

  @impl true
  def handle_info(:ensure, retry_ms), do: ensure(retry_ms)

  defp ensure(retry_ms) do
    case Engram.Indexing.ensure_collection() do
      :ok ->
        {:stop, :normal, retry_ms}

      {:error, reason} ->
        Logger.warning(
          "qdrant boot ensure_collection failed, retrying in #{retry_ms} ms: " <>
            Metadata.safe_reason(reason)
        )

        Process.send_after(self(), :ensure, retry_ms)
        {:noreply, retry_ms}
    end
  end
end
