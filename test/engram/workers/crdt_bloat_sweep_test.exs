defmodule Engram.Workers.CrdtBloatSweepTest do
  @moduledoc """
  The sweep's whole premise is that column lengths alone recover STORED sizes
  (#1706): a ciphertext is its payload plus a fixed tag, so no DEK is needed to
  size the database. Since #1872 R2 the payload may be compressed (format 1), so
  the gauges report stored bytes, not text size. If the arithmetic is wrong the
  gauges are wrong by a constant per row and nothing else notices — the numbers
  stay plausible. So these tests assert the byte totals EXACTLY against the
  stored ciphertext lengths rather than checking they are merely non-zero.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase, only: [as_prod_role: 1]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Crypto.Envelope
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
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    # upsert_note alone may leave crdt_state unset; a checkpoint is what writes
    # the column this sweep measures.
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), content)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    note
  end

  # Stored payload bytes (ciphertext minus the tag) of every live note's content,
  # read straight from the rows: what the sweep must report, in any format mix.
  defp stored_content_bytes(user) do
    {:ok, lens} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(n in Note, where: is_nil(n.deleted_at), select: n.content_ciphertext))
      end)

    lens |> Enum.map(&(byte_size(&1) - Engram.Crypto.Envelope.tag_bytes())) |> Enum.sum()
  end

  # Incompressible-ish text. The ratio floor (CrdtBloat.min_content_bytes/0) is
  # applied to STORED bytes, so a repetitive body that zstd shrinks below it
  # would silently leave the measured cohort.
  defp noisy(bytes), do: Base.encode64(:crypto.strong_rand_bytes(bytes))

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

    a = noisy(150)
    b = noisy(150)

    seeded_note(user, vault, "a.md", a)
    seeded_note(user, vault, "b.md", b)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, meta}
    assert meta == %{}

    assert m.notes == 2
    assert m.notes_with_state == 2
    assert m.notes_measured == 2
    assert_in_delta m.measured_at_unix, System.system_time(:second), 60

    # The load-bearing assertion. Off-by-the-tag would still look reasonable.
    # Stored bytes, not text size.
    assert m.content_bytes_total == stored_content_bytes(user)

    assert m.state_bytes_total > 0
    assert m.bloat_ratio_p50 > 0
    assert m.bloat_ratio_max >= m.bloat_ratio_p99
    assert m.bloat_ratio_p99 >= m.bloat_ratio_p50
    assert is_integer(m.notes_over_threshold)
  end

  test "sizes a mix of format 0 and format 1 rows as stored ciphertext minus tag", ctx do
    %{user: user, vault: vault} = ctx
    body = String.duplicate("mixed format body ", 20)

    prev = Application.get_env(:engram, :envelope_compression)
    on_exit(fn -> Application.put_env(:engram, :envelope_compression, prev) end)

    Application.put_env(:engram, :envelope_compression, false)
    seeded_note(user, vault, "old.md", body)
    Application.put_env(:engram, :envelope_compression, true)
    seeded_note(user, vault, "new.md", body)

    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(n in Note, select: {n.content_nonce, n.content_ciphertext}))
      end)

    assert [{_, _}, {_, f1_ct}] = Enum.sort_by(rows, fn {nonce, _} -> byte_size(nonce) end)
    f1_stored = byte_size(f1_ct) - Engram.Crypto.Envelope.tag_bytes()
    assert f1_stored < byte_size(body), "format 1 row must actually be compressed"

    attach()
    assert :ok = perform_job(CrdtBloatSweep, %{})
    assert_receive {:sweep, m, _meta}

    # Independent oracle: the format 0 row is exactly the text, the format 1 row
    # is its own stored length (read above), neither derived by the sweep.
    assert m.content_bytes_total == byte_size(body) + f1_stored
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

    kept = noisy(100)
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
    assert m.content_bytes_total == stored_content_bytes(user)
  end

  # The defect staging caught (2026-09-18): 1,932 of 5,277 notes held under 100
  # bytes, most of them a 2-byte Yjs doc, and they pinned p90 and p99 to exactly
  # 2.0 — which reads as "10% of notes carry 2x bloat" and is really "37% of
  # notes are empty". Percentiles must ignore them; byte totals must not,
  # because those bytes are really on disk.
  test "tiny notes are excluded from percentiles but counted in byte totals", ctx do
    %{user: user, vault: vault} = ctx

    real = noisy(150)
    seeded_note(user, vault, "real.md", real)

    tiny = "x"
    for i <- 1..5, do: seeded_note(user, vault, "tiny#{i}.md", tiny)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})
    assert_receive {:sweep, m, _meta}

    assert m.notes == 6, "every note is counted in the population"
    assert m.notes_with_state == 6
    assert m.notes_measured == 1, "only the real note is eligible for a ratio"

    # Every note's bytes still count toward storage. A 1-char note is format 1
    # raw: its stored payload is the char plus the 1-byte format prefix.
    assert m.content_bytes_total == stored_content_bytes(user)
    assert m.content_bytes_total >= 5 * (byte_size(tiny) + 1)

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

    with_state = noisy(120)
    seeded_note(user, vault, "stateful.md", with_state)

    # upsert_note without a checkpoint leaves crdt_state unset on this row.
    stateless = noisy(120)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "bare.md", "content" => stateless}, actor: "api")

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
    assert m.content_bytes_total == stored_content_bytes(user)
  end

  # The guard used to live in `perform/1`, which left the hand-invocation route
  # the @doc advertises bypassing it entirely. On a SaaS node with RLS enforced
  # and no maintenance pool that writes notes=0/ratio=0 into gauges that never
  # expire — the lying oracle the guard exists to prevent, reached through the
  # documented entry point. Both routes must refuse identically.
  test "measure_and_emit/0 carries the same refusal as perform/1" do
    # As the RLS-subject role with no maintenance pool, both routes must
    # refuse rather than emit zeroes.
    assert {:returned, {:error, :tenancy_unsafe}} =
             as_prod_role(fn -> CrdtBloatSweep.measure_and_emit() end)

    assert {:returned, {:error, :tenancy_unsafe}} =
             as_prod_role(fn -> perform_job(CrdtBloatSweep, %{}) end)
  end

  # Overwrite a note's stored sizes directly: the sweep reads only column
  # lengths, so random bytes of a chosen length are an exact fixture.
  defp sized!(user, note, state_bytes, content_bytes) do
    tag = Envelope.tag_bytes()

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [
            crdt_state_ciphertext: :crypto.strong_rand_bytes(state_bytes + tag),
            content_ciphertext: :crypto.strong_rand_bytes(content_bytes + tag)
          ]
        )
      end)
  end

  defp bump_version!(user, note, by) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          inc: [version: by],
          set: [updated_at: NaiveDateTime.utc_now()]
        )
      end)
  end

  describe "#2097 alert thresholds" do
    setup do
      Engram.Cache.evict(:crdt_sweep_versions, :last)
      on_exit(fn -> Engram.Cache.evict(:crdt_sweep_versions, :last) end)
    end

    test "over 5x counts only at or above the 64 KB state floor", ctx do
      %{user: user, vault: vault} = ctx
      floor = CrdtBloat.alert_min_state_bytes()

      # #2097's note: 5.7x but 19 KB of state. Heavy editing, costs nothing.
      small = seeded_note(user, vault, "small.md", noisy(150))
      sized!(user, small, 19_000, 3_400)

      big = seeded_note(user, vault, "big.md", noisy(150))
      sized!(user, big, floor, 3_400)

      attach()
      assert :ok = perform_job(CrdtBloatSweep, %{})
      assert_receive {:sweep, m, _}
      assert m.notes_over_threshold == 1
    end

    test "per-note write rate is a delta against the previous sweep", ctx do
      %{user: user, vault: vault} = ctx
      looping = seeded_note(user, vault, "loop.md", noisy(150))
      steady = seeded_note(user, vault, "steady.md", noisy(150))

      attach()

      # No baseline on the first run: the keys are absent, not a fake 0.
      assert :ok = perform_job(CrdtBloatSweep, %{})
      assert_receive {:sweep, first, _}
      refute Map.has_key?(first, :save_rate_max_per_hour)
      refute Map.has_key?(first, :notes_save_rate_over_threshold)

      bump_version!(user, looping, 200)
      bump_version!(user, steady, 50)

      assert :ok = perform_job(CrdtBloatSweep, %{})
      assert_receive {:sweep, second, _}
      assert second.save_rate_max_per_hour == 200
      assert second.notes_save_rate_over_threshold == 1
    end
  end
end
