defmodule Engram.Vector.FilterId do
  @moduledoc """
  Qdrant filter ids for v5 points (spec 3.3b). A filter id is the first 128
  bits of a per-user HMAC, written as 32 lowercase hex digits: the undashed
  UUID form, which a Qdrant `uuid` index parses like the dashed one and which
  saves 4 bytes per id on every point (the payload size test). Postgres keeps
  the full 32-byte HMACs; `from_hmac/1` is the only bridge, so the two sinks
  agree by construction.

  Frontmatter keys and values are HMAC'd in separate domains, so a key and a
  value with the same text (or a value and a path) never share an id.
  """

  alias Engram.Crypto
  alias Engram.Notes.OkfFields

  @spec from_hmac(binary() | nil) :: String.t() | nil
  def from_hmac(nil), do: nil

  def from_hmac(<<head::binary-size(16), _rest::binary>>),
    do: Base.encode16(head, case: :lower)

  @doc "An Ecto UUID (user_id, vault_id) in the same undashed form."
  @spec uuid(String.t()) :: String.t()
  def uuid(id) when is_binary(id), do: String.replace(id, "-", "")

  @doc "Full HMAC of a frontmatter key name (Postgres `key_hmac`)."
  @spec key_hmac(binary(), String.t()) :: binary()
  def key_hmac(filter_key, key), do: Crypto.hmac_field(filter_key, "fmk:" <> norm(key))

  @doc "Full HMAC of a frontmatter string value (Postgres `*_hmac`, `value_hmac`)."
  @spec value_hmac(binary(), String.t()) :: binary()
  def value_hmac(filter_key, value), do: Crypto.hmac_field(filter_key, value_input(value))

  @doc false
  # The HMAC input of a value, for DEK rotation's recompute (`hmac_field/2`).
  @spec value_input(String.t()) :: String.t()
  def value_input(value), do: "fmv:" <> norm(value)

  @spec attr(binary(), String.t()) :: String.t()
  def attr(filter_key, key), do: from_hmac(key_hmac(filter_key, key))

  @spec attr_value(binary(), String.t()) :: String.t()
  def attr_value(filter_key, value), do: from_hmac(value_hmac(filter_key, value))

  # Same canonical form as the `type` blind index, so a filter for `Draft`
  # matches `draft`.
  defp norm(s), do: OkfFields.normalize_type(s)
end
