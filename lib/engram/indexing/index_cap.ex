defmodule Engram.Indexing.IndexCap do
  @moduledoc """
  Per-user cap on how many notes get indexed for search.

  This caps what is **indexed**, never what **syncs**. A user's whole vault
  always syncs; only the first N notes become searchable. Capping sync would
  leave a half-synced vault on first sync, which reads as "Engram is broken"
  rather than "Engram is limited" — see the pricing decision log.

  Rank is server-side creation time among **live** notes, so deleting a note
  frees a slot. The consequence is that a user's NEWEST work is what falls
  outside the cap, which is why `counts/1` exists: the number is surfaced in the
  UI rather than letting note 2001 silently return nothing.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Notes.Note
  alias Engram.Repo

  @doc """
  True when this note is inside the user's indexed-note cap.

  Uncapped tiers (`nil` / `:unlimited`) short-circuit without touching the DB —
  this runs on every index, so the paid path must stay free.
  """
  @spec within_cap?(Note.t()) :: boolean()
  def within_cap?(%Note{} = note) do
    user = Engram.Accounts.get_user!(note.user_id)

    case Billing.effective_limit(user, :indexed_notes_cap) do
      cap when is_integer(cap) -> rank_of(note) < cap
      _ -> true
    end
  end

  @doc """
  `%{indexed: n, total: m}` live notes for a user — what the UI renders as
  "2,000 of 4,312 notes indexed".

  `indexed` is `min(total, cap)`, not a count of rows actually in Qdrant. That
  is deliberate: the true count lags by the Oban queue depth, so reporting it
  would make the number drift during a bulk import and read as data loss. The
  cap is the contract; the queue is an implementation detail.
  """
  @spec counts(map()) :: %{indexed: non_neg_integer(), total: non_neg_integer()}
  def counts(user) do
    total = live_note_count(user.id)

    indexed =
      case Billing.effective_limit(user, :indexed_notes_cap) do
        cap when is_integer(cap) -> min(total, cap)
        _ -> total
      end

    %{indexed: indexed, total: total}
  end

  # Live notes this user created BEFORE this one. Ties on created_at break by
  # id so the rank is stable rather than flapping between two notes written in
  # the same microsecond — which is common during a bulk first sync.
  defp rank_of(%Note{} = note) do
    Repo.one(
      from(n in Note,
        where: n.user_id == ^note.user_id and n.kind == "note" and is_nil(n.deleted_at),
        where:
          n.created_at < ^note.created_at or
            (n.created_at == ^note.created_at and n.id < ^note.id),
        select: count(n.id)
      ),
      skip_tenant_check: true
    ) || 0
  end

  defp live_note_count(user_id) do
    Repo.one(
      from(n in Note,
        where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
        select: count(n.id)
      ),
      skip_tenant_check: true
    ) || 0
  end
end
