defmodule Engram.ServiceConfig.Flags.FileSource do
  @moduledoc """
  Reads the staging flags file (`SERVICE_FLAGS_FILE`) for
  `Engram.ServiceConfig.Flags`, and owns the body cap both sources share.

  Its own small module so the sobelow `Traversal.FileModule` pin on the read
  does not move every time `flags.ex` changes
  (`docs/context/sobelow-silent-no-op-and-fingerprint-skips.md`). The path
  comes only from operator env set by Terraform, never from a request; the
  file is opened read-only and at most `max_bytes/0` + 1 bytes are read.
  """

  # Bytes; the reviewed file is a few KB.
  @max_bytes 256 * 1024

  @doc "The largest flags document accepted, from either source."
  # No @spec: dialyzer's :underspecs flags `pos_integer()` against the literal.
  def max_bytes, do: @max_bytes

  @doc """
  `{:ok, body, mtime}` (unix seconds). The body is cut at `max_bytes/0` + 1, so
  an oversized file reads as over the cap without being loaded whole.
  """
  @spec read(String.t()) :: {:ok, binary(), integer()} | {:error, term()}
  def read(path) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, body} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      {:ok, if(is_binary(body), do: body, else: ""), mtime}
    end
  end
end
