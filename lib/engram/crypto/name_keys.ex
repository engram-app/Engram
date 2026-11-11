defmodule Engram.Crypto.NameKeys do
  @moduledoc """
  The keys derived from a stored name, shared by every table that stores one
  (`Engram.Notes.Name` for notes and attachments, `Engram.Folders.Folder` for
  folder rows; O(1) folder rename plan S2):

    * `ci_hmac/3`: the casefolded blind index, in the caller's own domain, so
      two names that differ only by case share it (Obsidian on macOS and
      Windows treats them as one file), with the lowercasing `Engram.Links`
      uses;
    * `stamp/1`: which ciphertext a row's name keys were computed from (its
      nonce plus `version/0`); keys are current only while it matches;
    * `unreadable/1`: the stamp of a row whose source never decrypts, so a
      backfill leaves it alone (out of the stale set) until a writer gives it
      a fresh ciphertext. `Engram.Search.NameTerms` marks its skipped rows
      the same way.
  """

  alias Engram.Crypto

  # Bump to make every name stamp stale (a change to what a name's keys are).
  @version <<1>>

  @doc "The version byte every name stamp ends with."
  @spec version() :: <<_::8>>
  def version, do: @version

  @doc "The stamp of name keys derived from the ciphertext under `nonce`."
  @spec stamp(binary()) :: nonempty_binary()
  def stamp(nonce) when is_binary(nonce), do: nonce <> @version

  @doc "The casefolded `name_ci_hmac` of `name` in `domain`."
  @spec ci_hmac(binary(), String.t(), String.t()) :: binary()
  def ci_hmac(filter_key, domain, name),
    do: Crypto.hmac_field(filter_key, domain <> String.downcase(name))

  @doc "The stamp that parks a row whose source does not decrypt."
  @spec unreadable(binary()) :: nonempty_binary()
  def unreadable(stamp) when is_binary(stamp), do: <<0>> <> stamp
end
