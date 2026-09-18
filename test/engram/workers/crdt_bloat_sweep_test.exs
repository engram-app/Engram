defmodule Engram.Workers.CrdtBloatSweepTest do
  @moduledoc """
  The sweep's whole premise is that column lengths alone recover plaintext sizes
  (#1706): AES-GCM ciphertext is plaintext-length plus a fixed tag, so no DEK is
  needed to size the database. If that arithmetic is wrong the gauges are wrong
  by a constant per row and nothing else notices — the numbers stay plausible.
  So these tests assert the byte totals EXACTLY against known inputs rather than
  checking they are merely non-zero.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBloat, CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.CrdtBloatSweep

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtBloatSweepTest", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp seeded_note(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})

    # upsert_note alone may leave crdt_state unset; a checkpoint is what writes
    # the column this sweep measures.
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), content)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    note
  end

  defp attach do
    test_pid = self()
    id = "bloat-sweep-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:engram, :crdt, :state_sweep],
      fn _e, meas, meta, _ -> send(test_pid, {:sweep, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "sizes every stored note from column lengths alone", ctx do
    %{user: user, vault: vault} = ctx

    a = String.duplicate("alpha content here ", 8)
    b = String.duplicate("beta ", 40)
    assert byte_size(a) >= CrdtBloat.min_content_bytes()
    assert byte_size(b) >= CrdtBloat.min_content_bytes()

    seeded_note(user, vault, "a.md", a)
    seeded_note(user, vault, "b.md", b)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, meta}
    assert meta == %{}

    assert m.notes == 2
    assert m.notes_with_state == 2
    assert m.notes_measured == 2

    # The load-bearing assertion. Off-by-the-tag would still look reasonable.
    assert m.content_bytes_total == byte_size(a) + byte_size(b)

    assert m.state_bytes_total > 0
    assert m.bloat_ratio_p50 > 0
    assert m.bloat_ratio_max >= m.bloat_ratio_p99
    assert m.bloat_ratio_p99 >= m.bloat_ratio_p50
    assert is_integer(m.notes_over_threshold)
  end

  test "an empty database reports zeroes rather than raising", ctx do
    %{user: _user} = ctx

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, _meta}
    assert m.notes == 0
    assert m.notes_with_state == 0
    assert m.notes_measured == 0
    assert m.bloat_ratio_p50 == 0.0
    assert m.bloat_ratio_max == 0.0
    assert m.state_bytes_total == 0
    assert m.notes_over_threshold == 0
  end

  test "soft-deleted notes are excluded", ctx do
    %{user: user, vault: vault} = ctx

    kept = String.duplicate("kept content ", 10)
    seeded_note(user, vault, "kept.md", kept)
    gone = seeded_note(user, vault, "gone.md", "tombstoned content")

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^gone.id),
          set: [deleted_at: DateTime.utc_now()]
        )
      end)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, _meta}
    assert m.notes == 1
    assert m.content_bytes_total == byte_size(kept)
  end

  # The defect staging caught (2026-09-18): 1,932 of 5,277 notes held under 100
  # bytes, most of them a 2-byte Yjs doc, and they pinned p90 and p99 to exactly
  # 2.0 — which reads as "10% of notes carry 2x bloat" and is really "37% of
  # notes are empty". Percentiles must ignore them; byte totals must not,
  # because those bytes are really on disk.
  test "tiny notes are excluded from percentiles but counted in byte totals", ctx do
    %{user: user, vault: vault} = ctx

    real = String.duplicate("a real note body ", 12)
    assert byte_size(real) >= CrdtBloat.min_content_bytes()
    seeded_note(user, vault, "real.md", real)

    tiny = "x"
    for i <- 1..5, do: seeded_note(user, vault, "tiny#{i}.md", tiny)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})
    assert_receive {:sweep, m, _meta}

    assert m.notes == 6, "every note is counted in the population"
    assert m.notes_with_state == 6
    assert m.notes_measured == 1, "only the real note is eligible for a ratio"

    # Every note's bytes still count toward storage.
    assert m.content_bytes_total == byte_size(real) + 5 * byte_size(tiny)

    # With the tiny docs excluded the percentiles collapse onto the one real
    # note — if they leaked in, p90/p99 would be pulled far above p50.
    assert_in_delta m.bloat_ratio_p50, m.bloat_ratio_p99, 0.0001
    assert m.bloat_ratio_max == m.bloat_ratio_p50
  end

  # Migration 20260706210000 NULLed crdt_state for every note and nothing
  # re-seeds it (see CrdtCheckpoint). Those notes cost content bytes and no
  # state bytes. Scoping the sums to rows WITH state would drop them and report
  # a state/content ratio higher than the database's actual one — which is the
  # number #609 sizes storage against.
  test "notes with no CRDT state still count toward content bytes", ctx do
    %{user: user, vault: vault} = ctx

    with_state = String.duplicate("has a crdt snapshot ", 8)
    seeded_note(user, vault, "stateful.md", with_state)

    # upsert_note without a checkpoint leaves crdt_state unset on this row.
    stateless = String.duplicate("never checkpointed ", 8)
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "bare.md", "content" => stateless})

    {:ok, {1, _}} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})
    assert_receive {:sweep, m, _meta}

    assert m.notes == 2
    assert m.notes_with_state == 1, "only one row carries a snapshot"

    # The load-bearing part: the stateless note's bytes are still on disk.
    assert m.content_bytes_total == byte_size(with_state) + byte_size(stateless)
  end
end
