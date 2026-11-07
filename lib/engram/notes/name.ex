defmodule Engram.Notes.Name do
  @moduledoc """
  A note's or attachment's own name: the last segment of its path, extension
  kept (O(1) folder rename plan, Engram#2523, S2 expand). With `folder_ref_id`
  it is the row's whole location, so a later release derives the path from the
  folder chain plus this name instead of storing it per row.

  `keys/6` is the one place the name columns are computed. Every path writer
  calls it with the path it encrypts and that ciphertext's nonce: notes
  through `Engram.Notes`' path builder (`inject_phase_b_fields/6` and the
  folder rename cascade), attachments through `Engram.Attachments.path_attrs/4`,
  DEK rotation where it rewraps a path.

  Columns: `name_ciphertext` / `name_nonce` (AAD `aad_for_row(table, :name,
  id)`), `name_hmac` and `name_ci_hmac` (casefolded) in their own HMAC domains,
  and `name_stamp`, the source `path_nonce` plus `version/0`.

  Reader rule (S3 on): a row's name is current only while `name_stamp ==
  stamp(path_nonce)`. A writer that rewrites the path without the name (the
  previous release during a rolling deploy, a rollback, a legacy AAD rebind)
  draws a fresh path nonce, so its row stops matching. `NoteName` heals those
  rows; until then a reader decrypts the path.
  """

  alias Engram.Crypto
  alias Engram.Crypto.Envelope

  # Bump to make every stamp stale (a change to what a name is).
  @version <<1>>
  @name_domain "note-name\0"
  @ci_domain "note-name-ci\0"
  @columns [:name_ciphertext, :name_nonce, :name_hmac, :name_ci_hmac, :name_stamp]
  @tables [:notes, :attachments]

  @doc "The name columns, in `keys/6` order."
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc "The version byte every `name_stamp` ends with."
  @spec version() :: binary()
  def version, do: @version

  @doc "The stamp of a name derived from the ciphertext under `nonce`."
  @spec stamp(binary()) :: binary()
  def stamp(nonce) when is_binary(nonce), do: nonce <> @version

  @doc "The name of `path`: its last segment."
  @spec of_path(String.t()) :: String.t()
  def of_path(path), do: path |> String.split("/") |> List.last()

  @doc "`name_hmac` of a name under a user's filter key."
  @spec hmac(binary(), String.t()) :: binary()
  def hmac(filter_key, name), do: Crypto.hmac_field(filter_key, @name_domain <> name)

  @doc """
  `name_ci_hmac`: the casefolded key two names that differ only by case share
  (Obsidian on macOS and Windows treats them as one file), the lowercasing
  `Engram.Links` uses.
  """
  @spec ci_hmac(binary(), String.t()) :: binary()
  def ci_hmac(filter_key, name),
    do: Crypto.hmac_field(filter_key, @ci_domain <> String.downcase(name))

  @doc """
  The name columns of the `table` row `row_id` at `path`, whose path
  ciphertext is under `path_nonce`. A keyword list to splice into the row's
  write next to its path columns.
  """
  @spec keys(:notes | :attachments, <<_::256>>, binary(), Ecto.UUID.t(), String.t(), binary()) ::
          keyword()
  def keys(table, dek, filter_key, row_id, path, path_nonce) when table in @tables do
    name = of_path(path)
    {ct, nonce} = Envelope.encrypt(name, dek, Crypto.aad_for_row(table, :name, row_id))

    [
      name_ciphertext: ct,
      name_nonce: nonce,
      name_hmac: hmac(filter_key, name),
      name_ci_hmac: ci_hmac(filter_key, name),
      name_stamp: stamp(path_nonce)
    ]
  end

  @doc "Decrypts a stored name of the `table` row `row_id`."
  @spec decrypt(:notes | :attachments, <<_::256>>, Ecto.UUID.t(), binary(), binary()) ::
          {:ok, String.t()} | :error
  def decrypt(table, dek, row_id, ciphertext, nonce) when table in @tables,
    do: Envelope.decrypt(ciphertext, nonce, dek, Crypto.aad_for_row(table, :name, row_id))
end
