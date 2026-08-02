defmodule EngramWeb.BatchOps do
  @moduledoc """
  Shared helpers for the notes/folders batch endpoints (`batch_delete` /
  `batch_move`): input parsing and the post-commit PubSub fan-out. The
  response-shaping (`send_move_result`) stays in each controller — the two
  success bodies and error-clause sets genuinely differ (folders reports
  `moved_attachments` and maps cycle/bare-atom attachment-leg errors).
  """

  @doc """
  Casts a list of raw ids to UUIDs, rejecting the whole batch (`:error`)
  on the first non-UUID entry.
  """
  def parse_uuid_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_uuid(item) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  @doc "Casts a single raw id to a UUID; non-binaries are `:error`."
  def parse_uuid(s) when is_binary(s), do: Ecto.UUID.cast(s)
  def parse_uuid(_), do: :error

  # Move target is either a folder-marker UUID or the literal "root" sentinel
  # (vault root / top level — no marker). "root" must bypass the UUID cast.
  @doc "Parses a batch-move target: a marker UUID or the literal `\"root\"`."
  def parse_move_target("root"), do: {:ok, "root"}
  def parse_move_target(s) when is_binary(s), do: parse_uuid(s)
  def parse_move_target(_), do: :error

  @doc """
  Fans a committed batch op out to the user's sync channel. `event` is the
  per-resource name (`"notes.batch"` / `"folders.batch"`).
  """
  def broadcast_batch(user, vault, event, payload) do
    EngramWeb.Endpoint.broadcast!(
      "sync:#{user.id}:#{vault.id}",
      event,
      payload
    )
  end
end
