defmodule Engram.Notes.CrdtRoom do
  @moduledoc """
  The one door to `Yex.Sync.SharedDoc.update_doc/3`. Every server-side write or
  probe that runs a fun inside a live room goes through `update_doc/3` here.

  Why it exists: since y_ex 0.13 a fun that raises inside the room no longer
  crashes the room. `SharedDoc.update_doc/3` returns `{:error, e}` (or
  `{:error, {kind, reason}}` for a throw/exit) instead, and because
  `Yex.Doc.transaction/3` commits in `after`, any ops the fun applied before
  raising are already committed and broadcast. Before 0.13 that raise surfaced
  as a caller-side `:exit`, which every caller logged. Now it is a return value
  that a bare `SharedDoc.update_doc(room, fun); :ok` reports as success.

  This wrapper turns that return into a logged `{:error, {:room_raised, tag}}`
  so no caller can miss it. `tag` is a sanitized class name (never the
  exception message, which can carry a path or note text).

  Exits are NOT caught: `:noproc`, a call timeout or a room dying mid-call
  still exit the caller, exactly as `GenServer.call/3` does, because each
  caller treats those differently.
  """

  alias Engram.Logger.Metadata
  alias Yex.Sync.SharedDoc

  require Logger

  @default_timeout 5_000

  @type result :: :ok | {:error, {:room_raised, String.t()}}

  @doc """
  Runs `fun` inside `room` and returns `:ok`, or `{:error, {:room_raised, tag}}`
  when `fun` raised, threw or exited inside the room (logged at `:error`).

  Options: `:timeout` (default 5 s, the y_ex default) and `:metadata`, extra
  log metadata such as `note_id:` or `vault_id:`.
  """
  @spec update_doc(GenServer.server(), (Yex.Doc.t() -> term()), keyword()) :: result()
  def update_doc(room, fun, opts \\ []) when is_function(fun, 1) do
    case SharedDoc.update_doc(room, fun, Keyword.get(opts, :timeout, @default_timeout)) do
      :ok ->
        :ok

      {:error, raised} ->
        tag = raised_tag(raised)

        Logger.error(
          "crdt room write raised inside the room",
          Metadata.with_category(
            :error,
            :sync,
            Keyword.put(Keyword.get(opts, :metadata, []), :reason, tag)
          )
        )

        {:error, {:room_raised, tag}}
    end
  end

  # y_ex 0.13 `handle_call({:update_doc, fun})`: `rescue e -> {:error, e}`,
  # `catch kind, reason -> {:error, {kind, reason}}`.
  defp raised_tag({kind, reason}) when kind in [:throw, :exit],
    do: "#{kind} #{Metadata.safe_exit_reason(reason)}"

  defp raised_tag(exception), do: Metadata.safe_reason(exception)
end
