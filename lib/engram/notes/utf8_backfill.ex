defmodule Engram.Notes.Utf8Backfill do
  @moduledoc """
  #739 — find (and optionally repair) note rows whose decrypted content holds
  invalid UTF-8 at rest.

  Note text is stored as AES-GCM ciphertext over a Postgres `bytea` column,
  which bypasses Postgres's UTF-8 validation. Rows written before the
  #727/#740 write-time scrub can therefore carry invalid bytes (e.g. a
  multibyte char truncated to its lead byte). Every JSON egress now scrubs at a
  boundary, so this is no longer crash-critical — but the bad bytes persist at
  rest until the row is rewritten.

  `scan/1` decrypts each note WITHOUT the read-boundary scrub (so corruption is
  visible) and counts the offenders. `scan(fix: true)` additionally re-saves
  each corrupt note through the normal write path (`Notes.upsert_note/3`),
  which scrubs the content, re-encrypts, recomputes the content hash, and
  re-embeds — leaving the row valid at rest.

  Operator-invoked only (see `mix engram.utf8_audit`); never runs on deploy.
  In a release, `Mix` is absent — call `scan/1` directly via `rpc`.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.Helpers
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @text_fields [:content, :title, :folder]
  @empty %{scanned: 0, corrupt: 0, fixed: 0}

  @type tally :: %{
          scanned: non_neg_integer(),
          corrupt: non_neg_integer(),
          fixed: non_neg_integer()
        }

  @doc """
  Scans every active user's notes for invalid UTF-8 at rest.

  Options:
    * `:fix` (boolean, default `false`) — when true, rewrite each corrupt note
      through the normal write path so it becomes valid at rest.

  Returns a `%{scanned:, corrupt:, fixed:}` tally.
  """
  @spec scan(keyword()) :: tally()
  def scan(opts \\ []) do
    fix? = Keyword.get(opts, :fix, false)

    Accounts.list_users()
    |> Enum.reduce(@empty, fn user, acc -> scan_user(user, fix?, acc) end)
  end

  defp scan_user(user, fix?, acc) do
    case Crypto.ensure_user_dek(user) do
      {:ok, user} ->
        {:ok, notes} =
          Repo.with_tenant(user.id, fn ->
            # kind == "note" only: folder markers carry no content to scrub.
            Repo.all(from(n in Note, where: n.user_id == ^user.id and n.kind == "note"))
          end)

        Enum.reduce(notes, acc, fn note, acc -> scan_note(user, note, fix?, acc) end)

      {:error, _} ->
        acc
    end
  end

  defp scan_note(user, note, fix?, acc) do
    acc = bump(acc, :scanned)

    case Crypto.decrypt_note_fields_unscrubbed(note, user) do
      {:ok, decrypted} ->
        if corrupt?(decrypted) do
          acc = bump(acc, :corrupt)
          if fix?, do: fix_note(user, decrypted, acc), else: acc
        else
          acc
        end

      {:error, reason} ->
        # A decrypt failure is a different incident class (key drift/tamper),
        # not UTF-8 corruption — surface it but keep scanning.
        Logger.warning("utf8_backfill: skipped undecryptable note #{note.id}: #{inspect(reason)}",
          category: :data
        )

        acc
    end
  end

  defp corrupt?(%Note{} = note) do
    Enum.any?(@text_fields, fn field -> invalid?(Map.get(note, field)) end) or
      invalid_tags?(note.tags)
  end

  defp invalid?(value) when is_binary(value), do: not String.valid?(value)
  defp invalid?(_), do: false

  defp invalid_tags?(tags) when is_list(tags), do: Enum.any?(tags, &invalid?/1)
  defp invalid_tags?(_), do: false

  # Re-save through the normal write path. We do NOT scrub the path: scrubbing
  # it would change the note's identity (path → a different HMAC) and create a
  # new row instead of updating this one. Corruption lives in the content
  # (title/folder/tags are re-derived from the scrubbed content by upsert).
  defp fix_note(user, %Note{} = decrypted, acc) do
    with {:ok, vault} <- Vaults.get_vault(user, decrypted.vault_id),
         {:ok, _note} <-
           Notes.upsert_note(user, vault, %{
             "path" => decrypted.path,
             "content" => Helpers.scrub_utf8(decrypted.content || "", :write),
             "mtime" => decrypted.mtime
           }) do
      bump(acc, :fixed)
    else
      other ->
        Logger.warning("utf8_backfill: failed to rewrite note #{decrypted.id}: #{inspect(other)}",
          category: :data
        )

        acc
    end
  end

  defp bump(acc, key), do: Map.update!(acc, key, &(&1 + 1))
end
