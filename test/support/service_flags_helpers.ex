defmodule Engram.ServiceFlagsHelpers do
  @moduledoc """
  Runs `Engram.ServiceConfig.Flags` on a temp file source (the staging
  shape) and drives its polls by hand. The flags live in node-wide
  `:persistent_term`, so every caller must be `async: false`.
  """

  import ExUnit.Callbacks

  alias Engram.ServiceConfig.Flags

  @doc "Configures a file source holding `doc`, starts the reader, waits for its first load."
  def start_flags(doc \\ %{}) do
    path =
      Path.join(System.tmp_dir!(), "service_flags_#{System.unique_integer([:positive])}.json")

    write(path, doc)
    use_source({:file, path})
    start_supervised!({Flags, {:file, path}})
    sync()
    path
  end

  @doc "Configures `source` (so put/delete see a managed key) without starting a reader."
  def use_source(source) do
    Application.put_env(:engram, :service_flags, source)

    on_exit(fn ->
      Application.delete_env(:engram, :service_flags)
      :persistent_term.erase({Flags, :flags})
      :persistent_term.erase({Flags, :paused})
      :persistent_term.erase({Engram.ServiceConfig.Overrides, :managed})
    end)
  end

  @doc "Rewrites the file and runs one poll."
  def write_flags(path, doc) do
    write(path, doc)
    poll()
  end

  @doc "Runs one poll and waits for it."
  def poll do
    send(Flags, :poll)
    sync()
  end

  @doc "A `paused_accounts` entry `seconds` from now (negative = expired)."
  def paused(id, seconds) do
    until = DateTime.utc_now(:second) |> DateTime.add(seconds) |> DateTime.to_iso8601()
    %{"id" => id, "until" => until}
  end

  defp sync, do: :sys.get_state(Flags)

  defp write(path, doc) when is_binary(doc), do: File.write!(path, doc)
  defp write(path, doc), do: File.write!(path, Jason.encode!(doc))
end
