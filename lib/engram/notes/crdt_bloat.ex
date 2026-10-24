defmodule Engram.Notes.CrdtBloat do
  @moduledoc """
  What counts as a measurable CRDT doc, for the bloat metrics in #1706.

  The ratio `state_bytes / content_bytes` is meaningless for a note with almost
  no content: an empty doc still carries a couple of bytes of Yjs framing, so it
  divides to a large number that describes framing overhead rather than
  tombstone accumulation.

  This is not hypothetical. Measured on staging, 2026-09-18, 5,277 notes:

      unfiltered   p50 1.07  p90 2.00  p99 2.00  max 12.75   1 note over 5x
      >= 100 bytes p50 1.02  p90 1.15  p99 1.62  max  1.77   0 notes over 5x

  1,932 of those notes hold under 100 bytes and most hold a 2-byte doc. They
  pinned p90 and p99 to exactly 2.0, which reads as "10% of notes carry 2x
  bloat" and is really "37% of notes are empty". A gate tuned against that
  number would be tuned against empty files.

  So the ratio is only reported for docs above `min_content_bytes/0`. Byte
  totals and sizes are still reported for EVERY note — those are true regardless
  of how small the note is, and they are what storage is actually spent on.
  """

  # 100 bytes. Below this the Yjs framing dominates and the ratio stops being
  # about the doc. Deliberately generous: real notes have a p50 of 1.1 KB, so
  # this excludes empties and stubs without reaching anything a user would
  # recognise as a note.
  @min_content_bytes 100

  @doc "Smallest projected content, in bytes, for which the bloat ratio is meaningful."
  def min_content_bytes, do: @min_content_bytes

  # 64 KB. A note only counts as bloated (the sweep's `notes_over_threshold`,
  # the alert behind it) when its ratio is over 5x AND its state is at least
  # this big. #2097: the alert fired on one note with 712 checkpoints in 10h,
  # 19 KB of state over 3.4 KB of content (5.7x). Each checkpoint leaves ~27 B
  # of deletion history, which is normal heavy editing and costs nothing; 64 KB
  # is where bloat starts to cost bytes and where the flatten-gate work (#1707)
  # would be worth reopening.
  @alert_min_state_bytes 65_536

  @doc "Smallest stored CRDT state, in bytes, that `notes_over_threshold` counts."
  def alert_min_state_bytes, do: @alert_min_state_bytes

  # Writes per note per hour (each bumps `notes.version`: a checkpoint, or a
  # REST/MCP write) above which the sweep counts a note as being in a save
  # loop. The heaviest real editor #2097 found averaged ~71/h (712 in 10h);
  # 120 leaves headroom over that, and a machine edit loop runs far past it.
  @save_rate_threshold 120

  @doc "Per-note writes per hour that `notes_save_rate_over_threshold` counts."
  def save_rate_threshold, do: @save_rate_threshold

  @doc """
  Bloat ratio for a doc, or `nil` when the content is too small to divide by.

  `nil` means "do not record a sample", not "zero" — a zero would drag the
  distribution down just as the empties dragged it up.
  """
  @spec ratio(non_neg_integer(), non_neg_integer()) :: float() | nil
  def ratio(state_bytes, content_bytes)
      when is_integer(state_bytes) and is_integer(content_bytes) do
    if content_bytes >= @min_content_bytes, do: state_bytes / content_bytes
  end
end
