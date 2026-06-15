defmodule Mix.Tasks.Engram.StripQdrantPlaintext do
  @shortdoc "Strip leaked plaintext source_path/folder/tags from Qdrant payloads (#590)"

  @moduledoc """
  #590 backfill — remove plaintext `source_path`, `folder`, and `tags` from
  every existing Qdrant point's payload.

  Points written before the #590 fix carry these note-metadata fields in
  cleartext. The display values now live only in the encrypted `notes` row
  (rehydrated at search time), and the `*_hmac` fields carry all filter load,
  so the plaintext copies are pure leak with no remaining reader. This issues
  one Qdrant payload-key delete over a match-all filter — vectors and every
  other payload key (including the hmacs and the encrypted title/text) are
  untouched. No re-embedding.

  This task is a dev/CI convenience (`mix engram.strip_qdrant_plaintext`).
  In a RELEASE, `Mix` is not loaded, so invoke the plain function directly —
  do NOT call this task module via rpc:

      docker exec engram-saas /app/bin/engram rpc \
        'Engram.Vector.Qdrant.delete_leaked_plaintext_keys() |> IO.inspect()'

  Idempotent: deleting an absent payload key is a no-op, so re-running is safe.
  """

  use Mix.Task

  alias Engram.Vector.Qdrant

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("Stripping leaked plaintext (source_path/folder/tags) from all Qdrant payloads...")

    case Qdrant.delete_leaked_plaintext_keys() do
      :ok ->
        IO.puts("done — plaintext metadata removed from existing points")

      {:error, reason} ->
        Mix.raise("delete_leaked_plaintext_keys failed: #{inspect(reason)}")
    end
  end
end
