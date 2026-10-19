defmodule Engram.Notes.TagsTerm do
  @moduledoc """
  Decodes a note's decrypted tag list (`notes.tags_ciphertext` holds
  `:erlang.term_to_binary(tags)`).

  Its own small file so Sobelow's pinned `Misc.BinToTerm` fingerprint, which
  includes the line number, stays put. Inside `notes.ex` it shifted on most PRs
  and broke CI (docs/context/sobelow-silent-no-op-and-fingerprint-skips.md).

  Callers pass bytes that just passed AES-GCM authentication under the user's
  DEK with row-bound AAD, so a substituted ciphertext fails before it gets
  here, and `[:safe]` refuses to mint atoms. Keep it that way: never call this
  on bytes that did not come out of an authenticated decrypt.
  """

  @spec decode!(binary()) :: [String.t()]
  def decode!(plaintext), do: :erlang.binary_to_term(plaintext, [:safe])
end
