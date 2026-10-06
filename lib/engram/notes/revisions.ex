defmodule Engram.Notes.Revisions do
  @moduledoc """
  The version-history write path (#1710, epic #609).

  `record_write/4` runs inside a content write's own transaction, right after
  that write's fenced UPDATE succeeded, and decides whether the save starts a
  new version. A new version starts when a different actor writes, when more
  than the session gap has passed since the note's last edit, or on the note's
  first save after history shipped.

  When it does, the version being closed gets a copy of the note's OLD content
  ciphertext (the outbox). Nothing is decrypted, and nothing touches storage:
  it is bytes moving between two rows. `Engram.Workers.FinalizeRevision` moves
  the copy to storage after commit.

  ## Why after the write, not before

  A losing fenced write does not abort its transaction. The checkpoint's
  `update_all` returns `{0, _}` and the transaction commits, and
  `Notes.lookup_and_write` retries INSIDE the same transaction. A history step
  placed before the write would commit a version for a save that never
  happened. After a successful UPDATE the note row is locked until commit, so
  concurrent saves to one note serialize behind it, history step included.

  ## Recording is decided before the transaction

  Each caller evaluates `recording?/1` (the global switch AND the tier key)
  BEFORE opening its write transaction and passes the boolean in. The billing
  lookup then never runs under the vault row lock `Vaults.next_seq!` takes, and
  the same answer gates the post-commit finalize enqueue (`finalize?/3`).

  ## History never fails a save

  Every statement runs with `mode: :savepoint`, so a failure rolls back only
  itself and leaves the caller's transaction usable. The function-level rescue
  is total (every exception, not just database errors): a cast error or a bad
  AAD argument must not fail the caller's save any more than a constraint
  violation may. It logs at error level with a redacted reason and returns
  `:error`. That is a deliberate isolation boundary, not a silent swallow:
  losing one history entry is the right trade against losing the user's write,
  and the log line says so on its own key. `recording?/1` holds the same line
  for the billing lookup: a failure there logs and records nothing.
  """
  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Note, Revision}
  alias Engram.Repo

  require Logger

  @savepoint [mode: :savepoint]

  @doc """
  True when history is recorded for `user`: the global switch AND the tier key.
  Call it before the write's transaction. A failed billing lookup logs and
  answers false, so it never fails the save it gates.
  """
  @spec recording?(User.t()) :: boolean()
  def recording?(%User{} = user) do
    Application.get_env(:engram, :history_recording, false) and
      Billing.granted?(user, :history_enabled)
  rescue
    e ->
      Logger.error(
        "history recording? lookup failed user_id=#{user.id} err=#{Metadata.safe_reason(e)} " <>
          "at=#{Metadata.format_location(__STACKTRACE__)}",
        Metadata.with_category(:error, :sync, user_id: user.id)
      )

      false
  end

  @doc """
  Whether a committed write should enqueue `FinalizeRevision`: history was
  recording for it, it UPDATED an existing note (a create has no old text to
  copy), and the content changed.
  """
  @spec finalize?(boolean(), String.t() | nil, String.t() | nil) :: boolean()
  def finalize?(recording, prev_hash, new_hash),
    do: recording and is_binary(prev_hash) and prev_hash != new_hash

  @doc """
  Record a content write. Call inside the write's transaction, AFTER its fenced
  UPDATE succeeded. `existing` is the PRE-write row: its `content_ciphertext`
  is the text being replaced. `recording` is `recording?/1`, evaluated before
  the transaction opened.
  """
  @spec record_write(Note.t(), String.t(), boolean(), DateTime.t()) :: :ok | :skipped | :error
  def record_write(existing, actor, recording, now \\ DateTime.utc_now())

  def record_write(%Note{}, actor, false, _now) when is_binary(actor), do: :skipped

  def record_write(%Note{} = existing, actor, true, now) when is_binary(actor) do
    do_record_write(existing, actor, now)
  rescue
    e ->
      Logger.error(
        "history record_write failed note_id=#{existing.id} err=#{Metadata.safe_reason(e)} " <>
          "at=#{Metadata.format_location(__STACKTRACE__)}",
        Metadata.with_category(:error, :sync, note_id: existing.id)
      )

      :error
  end

  defp do_record_write(existing, actor, now) do
    case open_version(existing.id) do
      %Revision{actor: ^actor} = open ->
        if within_gap?(existing.updated_at, now),
          do: :ok,
          else: close_and_open(open, existing, actor, now)

      %Revision{} = open ->
        close_and_open(open, existing, actor, now)

      nil ->
        first_or_orphaned(existing, actor, now)
    end
  end

  # No open version. Either the note has no history at all (first save after
  # history shipped: keep a baseline of the text being replaced), or a later
  # issue left history without an open row (#1711 restore, #1712 prune). In
  # the second case still keep the text being replaced rather than lose it.
  defp first_or_orphaned(existing, actor, now) do
    copy_result =
      cond do
        not has_content?(existing) -> :ok
        any_history?(existing.id) -> insert_closed_copy(existing, "edit", actor, now)
        true -> insert_closed_copy(existing, "baseline", "baseline", now)
      end

    with :ok <- copy_result, do: insert_open(existing, actor, now)
  end

  defp close_and_open(open, existing, actor, now) do
    query = from(r in Revision, where: r.id == ^open.id and is_nil(r.closed_at))
    set = [closed_at: now, updated_at: now] ++ Map.to_list(copy_of(existing))

    case Repo.update_all(query, [set: set], @savepoint) do
      {1, _} -> insert_open(existing, actor, now)
      {0, _} -> refused(existing.id)
    end
  end

  defp insert_open(existing, actor, now) do
    %{
      note_id: existing.id,
      user_id: existing.user_id,
      vault_id: existing.vault_id,
      actor: actor,
      origin: origin_for(actor),
      session_started_at: now
    }
    |> Revision.open_changeset()
    |> insert(existing.id)
  end

  defp insert_closed_copy(existing, origin, actor, now) do
    %{
      note_id: existing.id,
      user_id: existing.user_id,
      vault_id: existing.vault_id,
      actor: actor,
      origin: origin,
      session_started_at: existing.updated_at || now,
      closed_at: now
    }
    |> Map.merge(copy_of(existing))
    |> Revision.closed_copy_changeset()
    |> insert(existing.id)
  end

  defp insert(changeset, note_id) do
    case Repo.insert(changeset, @savepoint) do
      {:ok, _} -> :ok
      {:error, _changeset} -> refused(note_id)
    end
  end

  defp refused(note_id) do
    Logger.error(
      "history version refused note_id=#{note_id}",
      Metadata.with_category(:error, :sync, note_id: note_id)
    )

    :error
  end

  defp open_version(note_id) do
    Repo.one(
      from(r in Revision, where: r.note_id == ^note_id and is_nil(r.closed_at)),
      @savepoint
    )
  end

  defp any_history?(note_id) do
    Repo.exists?(from(r in Revision, where: r.note_id == ^note_id), @savepoint)
  end

  # The outbox copy: the note's own ciphertext, still bound to the notes AAD of
  # note_id, plus the AAD-format marker needed to decrypt it later.
  defp copy_of(existing) do
    %{
      pending_ciphertext: existing.content_ciphertext,
      pending_nonce: existing.content_nonce,
      pending_dek_version: existing.dek_version,
      content_hash: existing.content_hash
    }
  end

  # An empty note encrypts to the bare AEAD tag. There is nothing to go back to.
  defp has_content?(%Note{content_ciphertext: ct}) when is_binary(ct),
    do: byte_size(ct) > Envelope.tag_bytes()

  defp has_content?(_), do: false

  defp within_gap?(%DateTime{} = last, now),
    do: DateTime.diff(now, last, :second) <= session_gap_seconds()

  defp within_gap?(_, _now), do: false

  defp session_gap_seconds,
    do: Application.get_env(:engram, :history_session_gap_minutes, 10) * 60

  defp origin_for("restore"), do: "restore"
  defp origin_for(_actor), do: "edit"

  @doc """
  Decrypt a version's outbox copy. It is the note's own ciphertext, so it
  decrypts exactly as `notes.content` would: notes AAD of note_id when the
  copied row was AAD-bound, empty AAD for a legacy row.
  """
  @spec decrypt_pending(Revision.t(), User.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt_pending(
        %Revision{pending_ciphertext: ct, pending_nonce: nonce, pending_dek_version: v} = rev,
        %User{} = user
      )
      when is_binary(ct) and is_binary(nonce) and is_integer(v) do
    aad =
      if v >= Crypto.row_version_aad_bound(),
        do: Crypto.aad_for_row(:notes, :content, rev.note_id),
        else: <<>>

    with {:ok, dek} <- Crypto.get_dek(user) do
      case Envelope.decrypt(ct, nonce, dek, aad) do
        {:ok, text} -> {:ok, text}
        :error -> {:error, :decrypt_failed}
      end
    end
  end

  def decrypt_pending(%Revision{}, _user), do: {:error, :nothing_pending}
end
