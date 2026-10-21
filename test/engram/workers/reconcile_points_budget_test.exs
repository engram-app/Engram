defmodule Engram.Workers.ReconcilePointsBudgetTest do
  # async: false: the RLS control drops the connection role, and the
  # limits_enforced toggle is global app env.
  use Engram.DataCase, async: false

  use Oban.Testing, repo: Engram.Repo

  import Engram.IndexBudgetHelpers
  import Ecto.Query
  import Engram.RlsCase, only: [as_prod_role: 1]
  import Mox

  alias Engram.Billing.LimitKeys
  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings}

  # The v5 index budget is off by default (review H2); these tests are about it.
  setup :enable_index_budget

  setup :verify_on_exit!

  # Over 512 B: the chunker's min512 merge (v5) leaves each section alone,
  # so every section is still its own chunk.
  @pad String.duplicate("filler words here ", 30)

  @content """
  # Five

  ## One

  Alpha section text. #{@pad}

  ## Two

  Bravo section text. #{@pad}

  ## Three

  Charlie section text. #{@pad}

  ## Four

  Delta section text. #{@pad}

  ## Five

  Echo section text. #{@pad}
  """

  # Fake Qdrant: `status` is the collection status, `refuse` (:upsert or
  # :delete) answers that write 403 as strict mode would, and every write is
  # recorded in `writes` as {kind, body}.
  setup do
    {:ok, qdrant} = Agent.start_link(fn -> %{status: "green", refuse: nil, writes: []} end)
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      kind =
        cond do
          conn.method == "GET" -> :read
          conn.method == "PUT" and String.ends_with?(conn.request_path, "/points") -> :upsert
          String.ends_with?(conn.request_path, "/points/delete") -> :delete
          true -> :other
        end

      state = Agent.get(qdrant, & &1)
      if kind != :read, do: Agent.update(qdrant, &%{&1 | writes: &1.writes ++ [{kind, raw}]})

      {code, body} =
        cond do
          kind == :read -> {200, ~s({"result": {"status": "#{state.status}"}})}
          state.refuse == kind -> {403, ~s({"status": {"error": "strict mode"}})}
          true -> {200, ~s({"result": true})}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(code, body)
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    %{user: user, vault: vault, qdrant: qdrant}
  end

  defp qdrant_set(qdrant, changes), do: Agent.update(qdrant, &Map.merge(&1, Map.new(changes)))

  defp writes(qdrant, kind),
    do: for({^kind, body} <- Agent.get(qdrant, & &1.writes), do: Jason.decode!(body))

  defp cap, do: LimitKeys.default_for(:index_points_cap, :free)

  # `n` notes indexed at their content, `rows` chunk rows each, oldest first
  # (`updated_at` one minute apart, ending `offset` minutes ago).
  defp full_notes(user, vault, n, rows, opts \\ []) do
    ids =
      if Keyword.get(opts, :real, false),
        do: for(_ <- 1..n, do: insert_note(user, vault).id),
        else: clone_notes(user, vault, n)

    stamp!(user, ids,
      dense_indexed_hash: if(Keyword.get(opts, :dense, true), do: :content, else: nil)
    )

    # Oldest first: note i is `offset + n - i` minutes old.
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!(
          """
          UPDATE notes SET updated_at = now() - (($2::int + $3::int - u.i) * interval '1 minute')
          FROM unnest($1::uuid[]) WITH ORDINALITY AS u(id, i) WHERE notes.id = u.id
          """,
          [Enum.map(ids, &Ecto.UUID.dump!/1), Keyword.get(opts, :offset, 0), n]
        )
      end)

    seed_rows!(user, vault, ids, rows,
      token_count: 1,
      context_hmac: "h",
      char_end: Keyword.get(opts, :span, 1)
    )

    ids
  end

  defp insert_note(user, vault),
    do:
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "F#{System.unique_integer([:positive])}.md",
        content: "x"
      })

  # `n` copies of one fixture note, each with its own id and path_hmac, in one
  # statement: `insert_note!` costs ~12 ms a note. Their ciphertext is the
  # template's, so only a note made with `real: true` may run a pass.
  defp clone_notes(user, vault, n) do
    template = insert_note(user, vault)

    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        cols =
          Repo.query!(
            "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notes' ORDER BY ordinal_position"
          ).rows
          |> List.flatten()
          |> Enum.reject(&(&1 in ["id", "path_hmac"]))
          |> Enum.join(", ")

        %{rows: rows} =
          Repo.query!(
            """
            INSERT INTO notes (id, path_hmac, #{cols})
            SELECT gen_random_uuid(), decode(md5(random()::text || g), 'hex'), #{cols}
            FROM notes, generate_series(2, $2) g WHERE id = $1
            RETURNING id
            """,
            [Ecto.UUID.dump!(template.id), n]
          )

        [template.id | Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)]
      end)

    ids
  end

  # Floored notes: keyword-only rows (token_count NULL, no hmac) spanning
  # `span` characters, as many as `Indexing.floor_points/1` says,
  # newest last.
  defp floor_notes(user, vault, n, tier, span, opts \\ []) do
    ids = full_notes(user, vault, n, 0, Keyword.put(opts, :dense, false))
    stamp!(user, ids, index_tier: tier, chunk_count: Keyword.get(opts, :chunk_count))
    rows = Indexing.floor_points(span)
    seed_rows!(user, vault, ids, rows, token_count: nil, context_hmac: nil, char_end: span)
    ids
  end

  # Account filler in notes of 100 rows (under every per-note cap).
  defp filler(user, vault, total) do
    full = div(total, 100)
    if full > 0, do: full_notes(user, vault, full, 100, offset: 100_000)
    if rem(total, 100) > 0, do: full_notes(user, vault, 1, rem(total, 100), offset: 200_000)
    :ok
  end

  defp stamp!(user, ids, set) do
    {dense, set} = Keyword.pop(set, :dense_indexed_hash, :keep)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        q = from(n in Note, where: n.id in ^ids)

        q =
          case dense do
            :content ->
              update(q, [n],
                set: [embed_hash: n.content_hash, dense_indexed_hash: n.content_hash]
              )

            nil ->
              update(q, [n], set: [embed_hash: n.content_hash, dense_indexed_hash: nil])

            :keep ->
              q
          end

        Repo.update_all(q,
          set:
            [
              chunker_version: Markdown.chunker_version(),
              keyword_version: Engram.KeywordIndex.version(),
              embed_model: Indexing.embed_model()
            ] ++ set
        )
      end)
  end

  defp seed_rows!(_user, _vault, _ids, 0, _opts), do: :ok

  # Batches of about 2,000 rows, one transaction each: the vaults FK check
  # costs ~0.8 ms a row here, and one transaction must finish inside the
  # 15 s checkout.
  defp seed_rows!(user, vault, ids, rows, opts) do
    for batch <- Enum.chunk_every(ids, max(div(2_000, rows), 1)) do
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.query!(
            """
            INSERT INTO chunks
              (note_id, user_id, vault_id, position, char_start, char_end, qdrant_point_id,
               created_at, token_count, context_hmac)
            SELECT n, $2, $3, g, 0, $5, gen_random_uuid(), now(), $6, $7
            FROM unnest($1::uuid[]) n, generate_series(0, $4 - 1) g
            """,
            [
              Enum.map(batch, &Ecto.UUID.dump!/1),
              Ecto.UUID.dump!(user.id),
              Ecto.UUID.dump!(vault.id),
              rows,
              opts[:char_end],
              opts[:token_count],
              opts[:context_hmac]
            ]
          )
        end)
    end

    :ok
  end

  defp points(user) do
    {:ok, n} = Repo.with_tenant(user.id, fn -> Repo.aggregate(Chunk, :count) end)
    n
  end

  defp tiers(user, ids) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(n in Note, where: n.id in ^ids, select: {n.id, n.index_tier}))
      end)

    Map.new(rows)
  end

  defp reload(note) do
    {:ok, row} = Repo.with_tenant(note.user_id, fn -> Repo.get!(Note, note.id) end)
    row
  end

  defp rows_for(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.all(from(c in Chunk, where: c.note_id == ^note.id))
      end)

    rows
  end

  defp budget_jobs(kind) do
    for j <- all_enqueued(worker: RebuildStaleNote), j.args[kind[:key]] == kind[:value], do: j
  end

  defp run_budget_jobs do
    for j <- all_enqueued(worker: RebuildStaleNote) do
      assert :ok = perform_job(RebuildStaleNote, j.args)
      Repo.delete!(j)
    end
  end

  # Both arities: a RebuildStaleNote pass sends `purpose: :maintenance`.
  defp stub_embedder do
    embed = fn texts -> {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)} end
    Mox.stub(Engram.MockEmbedder, :embed_texts, embed)
    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts -> embed.(texts) end)
  end

  defp with_limits_enforced(value) do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, value)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)
  end

  # A real note floored by a real pass, `tier` kept.
  defp floored_note(user, vault, tier) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Five.md", content: @content})
    stamp!(user, [note.id], index_tier: tier)
    assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
    assert [%{token_count: nil}] = rows_for(note)
    assert reload(note).index_tier == tier
    assert reload(note).chunk_count == 5
    reload(note)
  end

  describe "demote" do
    test "over the cap demotes oldest-first to at or under it; notes kept; second sweep idle", %{
      user: user,
      vault: vault
    } do
      notes = div(cap() * 12, 1_000)
      ids = full_notes(user, vault, notes, 100, real: true)
      assert points(user) == div(cap() * 12, 10)
      before = UsageMeters.lifetime_embed_tokens(user.id)
      {:ok, note_count} = Repo.with_tenant(user.id, fn -> Repo.aggregate(Note, :count) end)

      assert {:ok, %{demoted: demoted, promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
      assert demoted > 0

      # The oldest `demoted` notes, every one of them dense, so "floor_paid".
      {old, new} = Enum.split(ids, demoted)
      t = tiers(user, ids)
      assert Enum.all?(old, &(t[&1] == "floor_paid"))
      assert Enum.all?(new, &is_nil(t[&1]))
      assert length(budget_jobs(key: "index_budget", value: "demote")) == demoted

      run_budget_jobs()
      assert points(user) <= cap()

      assert {:ok, ^note_count} =
               Repo.with_tenant(user.id, fn -> Repo.aggregate(Note, :count) end)

      assert UsageMeters.lifetime_embed_tokens(user.id) == before

      assert {:ok, %{demoted: 0, promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
      assert all_enqueued(worker: RebuildStaleNote) == []
    end

    test "1,000 over-cap notes demote 200 per tick across five ticks; red pauses", %{
      user: user,
      vault: vault,
      qdrant: qdrant
    } do
      # An override keeps the fixture small (and covers overrides): 1,000 old
      # 2-row notes, then 10 notes of 100 rows, so that keeping any old note
      # full would pass the cap (1,010 + 10 x 99 = 2,000).
      insert(:user_limit_override, user: user, key: "index_points_cap", value: %{"v" => 2_000})
      old = full_notes(user, vault, 1_000, 2, offset: 10_000)
      _new = full_notes(user, vault, 10, 100)

      qdrant_set(qdrant, status: "red")
      assert {:ok, %{demoted: 0, promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
      assert Enum.all?(Map.values(tiers(user, old)), &is_nil/1)
      qdrant_set(qdrant, status: "green")

      for _tick <- 1..5 do
        assert {:ok, %{demoted: 200}} = ReconcileEmbeddings.budget_sweep(20)
      end

      assert Enum.all?(Map.values(tiers(user, old)), &(&1 == "floor_paid"))
      assert {:ok, %{demoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
    end

    test "billing disabled never demotes", %{user: user, vault: vault} do
      with_limits_enforced(false)
      ids = full_notes(user, vault, div(cap() * 12, 1_000), 100)

      assert {:ok, %{demoted: 0, promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
      assert Enum.all?(Map.values(tiers(user, ids)), &is_nil/1)
    end

    test "selection without the maintenance pool finds nobody (control)", %{
      user: user,
      vault: vault
    } do
      full_notes(user, vault, div(cap() * 12, 1_000), 100)

      assert {:returned, {:ok, %{demoted: 0, promoted: 0}}} =
               as_prod_role(fn -> ReconcileEmbeddings.budget_sweep(20) end)

      assert {:ok, %{demoted: demoted}} = ReconcileEmbeddings.budget_sweep(20)
      assert demoted > 0
    end
  end

  describe "promote" do
    test "promotes newest floor notes while the projection stays under 90%; none at 95%", %{
      user: user,
      vault: vault
    } do
      # Each floor note's stamped chunk count is 100: what it costs once
      # promoted (its 1-character span would estimate 1).
      filler(user, vault, div(cap() * 85, 100) - 10)
      floors = floor_notes(user, vault, 10, "floor", 1, chunk_count: 100)
      assert points(user) == div(cap() * 85, 100)

      assert {:ok, %{demoted: 0, promoted: promoted}} = ReconcileEmbeddings.budget_sweep(20)
      assert promoted > 0
      assert div(cap() * 85, 100) + 100 * promoted < div(cap() * 90, 100)
      assert div(cap() * 85, 100) + 100 * (promoted + 1) >= div(cap() * 90, 100)

      jobs = budget_jobs(key: "index_budget", value: "promote")

      assert Enum.sort(Enum.map(jobs, & &1.args["note_id"])) ==
               Enum.sort(Enum.take(floors, -promoted))
    end

    # A note over 1 MiB floors into one row per MiB. Read as "not floored
    # yet", it was re-demoted every tick and never promoted.
    test "a floor note of several rows promotes, and is not re-floored", %{
      user: user,
      vault: vault
    } do
      [big] = floor_notes(user, vault, 1, "floor", 3 * 1_048_576, chunk_count: 40)
      assert points(user) == Indexing.floor_points(3 * 1_048_576)

      assert {:ok, %{demoted: 0, promoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
      assert [%{args: %{"note_id" => ^big}}] = budget_jobs(key: "index_budget", value: "promote")
    end

    test "over the cap, a floor note of several rows gets no demote job", %{
      user: user,
      vault: vault
    } do
      filler(user, vault, cap() + 50)
      [big] = floor_notes(user, vault, 1, "floor", 3 * 1_048_576)

      ReconcileEmbeddings.budget_sweep(20)

      refute Enum.any?(all_enqueued(worker: RebuildStaleNote), &(&1.args["note_id"] == big))
    end

    test "at 95% nothing promotes", %{user: user, vault: vault} do
      filler(user, vault, div(cap() * 95, 100) - 10)
      floor_notes(user, vault, 10, "floor", 1)

      assert {:ok, %{demoted: 0, promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
      assert all_enqueued(worker: RebuildStaleNote) == []
    end

    test "a floor_paid promotion is unmetered", %{user: user, vault: vault} do
      note = floored_note(user, vault, "floor_paid")
      before = UsageMeters.lifetime_embed_tokens(user.id)
      stub_embedder()

      assert {:ok, %{promoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
      run_budget_jobs()

      promoted = reload(note)
      assert promoted.index_tier == nil
      assert promoted.dense_indexed_hash == promoted.content_hash
      assert length(rows_for(note)) == 5
      assert promoted.chunk_count == nil
      assert UsageMeters.lifetime_embed_tokens(user.id) == before
    end

    test "a floor promotion is metered", %{user: user, vault: vault} do
      note = floored_note(user, vault, "floor")
      before = UsageMeters.lifetime_embed_tokens(user.id)
      stub_embedder()

      assert {:ok, %{promoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
      run_budget_jobs()

      assert reload(note).index_tier == nil
      assert length(rows_for(note)) == 5
      assert UsageMeters.lifetime_embed_tokens(user.id) > before
    end

    test "an upgraded user promotes every floor note over successive sweeps", %{
      user: user,
      vault: vault
    } do
      insert(:subscription, user: user, tier: "pro", status: "active")
      floors = floor_notes(user, vault, 210, "floor", 1)

      assert {:ok, %{promoted: 200}} = ReconcileEmbeddings.budget_sweep(20)
      assert {:ok, %{promoted: 10}} = ReconcileEmbeddings.budget_sweep(20)
      assert {:ok, %{promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)

      ids = Enum.map(budget_jobs(key: "index_budget", value: "promote"), & &1.args["note_id"])
      assert Enum.sort(ids) == Enum.sort(floors)
    end

    test "at most 2,000 unmetered promoted points per user per day", %{user: user, vault: vault} do
      insert(:subscription, user: user, tier: "pro", status: "active")
      floor_notes(user, vault, 30, "floor_paid", 100 * 1024)

      assert {:ok, %{promoted: 20}} = ReconcileEmbeddings.budget_sweep(20)
      assert {:ok, %{promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
    end

    test "a raised per-note cap un-merges merged notes, unmetered", %{user: user, vault: vault} do
      [merged] = full_notes(user, vault, 1, 0)

      seed_rows!(user, vault, [merged], 60,
        token_count: nil,
        context_hmac: "h",
        char_end: 300 * 1024
      )

      stamp!(user, [merged], chunk_count: 300)

      # 300 chunks do not fit Free's per-note cap of 128: left merged.
      assert {:ok, %{promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)

      insert(:subscription, user: user, tier: "pro", status: "active")
      assert {:ok, %{promoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
      assert [job] = budget_jobs(key: "recap", value: true)
      assert job.args["note_id"] == merged
    end

    # Hysteresis: a merged note un-merges only at or below 0.75 x its cap, so
    # one of 100 chunks under Free's 128 stays merged and is never queued
    # (a recap would keep it merged, every day).
    test "a merged note above 0.75 x its cap is not queued to un-merge", %{
      user: user,
      vault: vault
    } do
      [merged] = full_notes(user, vault, 1, 0)
      seed_rows!(user, vault, [merged], 60, token_count: nil, context_hmac: "h", char_end: 100)
      stamp!(user, [merged], chunk_count: 100)

      assert {:ok, %{promoted: 0}} = ReconcileEmbeddings.budget_sweep(20)
      assert [] = budget_jobs(key: "recap", value: true)

      stamp!(user, [merged], chunk_count: 96)
      assert {:ok, %{promoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
    end

    test "a chunker version bump keeps floor notes on floor, unmetered", %{
      user: user,
      vault: vault
    } do
      note = floored_note(user, vault, "floor")
      filler(user, vault, div(cap() * 95, 100))
      before = UsageMeters.lifetime_embed_tokens(user.id)

      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [chunker_version: nil])
      end)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: ~U[2026-10-19 04:02:00Z])
      assert [job] = all_enqueued(worker: RebuildStaleNote)
      assert job.args["note_id"] == note.id
      assert :ok = perform_job(RebuildStaleNote, job.args)

      assert [%{token_count: nil}] = rows_for(note)
      assert reload(note).index_tier == "floor"
      assert UsageMeters.lifetime_embed_tokens(user.id) == before
    end
  end

  describe "tier writes compare-and-set" do
    test "a floor pass started before a promotion cannot re-stamp it floor", %{
      user: user,
      vault: vault,
      qdrant: qdrant
    } do
      note = floored_note(user, vault, "floor")
      {:ok, stale} = Crypto.maybe_decrypt_note_fields(note, user)
      [floor_row] = rows_for(note)
      qdrant_set(qdrant, writes: [])

      # The promotion lands while the floor pass runs.
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [index_tier: nil])
      end)

      assert {:error, :index_tier_changed} =
               Indexing.index_note_with_usage(stale, vault, user, [])

      assert reload(note).index_tier == nil
      assert [^floor_row] = rows_for(note)
      assert writes(qdrant, :upsert) == [] and writes(qdrant, :delete) == []
    end

    # Lost before planning: no Voyage call, no Qdrant write.
    test "a full pass started before a demotion cannot clear it", %{
      user: user,
      vault: vault,
      qdrant: qdrant
    } do
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "Five.md", content: @content})
      {:ok, stale} = Crypto.maybe_decrypt_note_fields(note, user)
      Mox.expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embedded") end)

      stamp!(user, [note.id], index_tier: "floor")

      assert {:error, :index_tier_changed} =
               Indexing.index_note_with_usage(stale, vault, user, [])

      assert reload(note).index_tier == "floor"
      assert rows_for(note) == []
      assert writes(qdrant, :upsert) == [] and writes(qdrant, :delete) == []
    end

    # Lost during the pass (the demotion lands while it reserves tokens):
    # refused at commit, rows untouched.
    test "a demotion landing mid-pass is refused at commit", %{user: user, vault: vault} do
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "Five.md", content: @content})
      {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)
      stub_embedder()

      demote = fn _tokens ->
        stamp!(user, [note.id], index_tier: "floor")
        true
      end

      assert {:error, :index_tier_changed} =
               Indexing.index_note_with_usage(decrypted, vault, user, reserve_tokens: demote)

      assert reload(note).index_tier == "floor"
      assert rows_for(note) == []
    end

    test "an emptied floor note clears its tier", %{user: user, vault: vault} do
      note = floored_note(user, vault, "floor")
      {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)

      assert {:ok, 0, 0, true} =
               Indexing.index_note_with_usage(%{decrypted | content: ""}, vault, user, [])

      assert reload(note).index_tier == nil
      assert rows_for(note) == []
    end
  end

  describe "every path that drops dense vectors stamps floor_paid, maintenance drops none" do
    setup %{user: user, vault: vault} do
      stub_embedder()
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "Five.md", content: @content})
      assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
      dense = reload(note)
      assert dense.dense_indexed_hash == dense.embed_hash
      %{note: dense}
    end

    # Evicts the 60 s override cache, which the setup's embed filled with a miss.
    defp cap_override(user, key, v) do
      insert(:user_limit_override, user: user, key: key, value: %{"v" => v})
      Engram.Billing.OverrideCache.evict(user.id)
    end

    test "the sweep's demotion", %{user: user, vault: vault, note: note} do
      cap_override(user, "index_points_cap", 3)
      sparse = full_notes(user, vault, 1, 2, dense: false)

      assert {:ok, %{demoted: 2}} = ReconcileEmbeddings.budget_sweep(20)
      assert tiers(user, [note.id | sparse]) == %{note.id => "floor_paid", hd(sparse) => "floor"}
    end

    test "an edit over the points budget", %{user: user, vault: vault, note: note} do
      cap_override(user, "index_points_cap", 3)
      {:ok, edited} = Crypto.maybe_decrypt_note_fields(note, user)
      edited = %{edited | content: @content <> "\n## Six\n\nFoxtrot section text. #{@pad}\n"}

      assert {:ok, 1, 0, false} = Indexing.index_note_with_usage(edited, vault, user, [])
      assert reload(note).index_tier == "floor_paid"
    end

    # Review M2: maintenance never floors a dense note; it keeps its points
    # and the sweep's demotion (above) is the one path that drops them.
    test "a version rebuild over the points budget keeps the dense points", %{
      user: user,
      note: note
    } do
      ids = Enum.map(rows_for(note), & &1.qdrant_point_id)
      cap_override(user, "index_points_cap", 3)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [chunker_version: nil])
        end)

      assert :ok = perform_job(RebuildStaleNote, %{"note_id" => note.id, "user_id" => user.id})
      assert Enum.map(rows_for(note), & &1.qdrant_point_id) == ids
      assert reload(note).index_tier == nil
    end

    test "a re-merge that would floor keeps the dense points", %{user: user, vault: vault} do
      big = Enum.map_join(1..400, "\n\n", &"Paragraph #{&1} #{String.duplicate("word ", 20)}")
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", content: big})
      assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
      assert reload(note).dense_indexed_hash != nil

      ids = Enum.map(rows_for(note), & &1.qdrant_point_id)
      # One point for ~40 KB: past the merged-point ceiling, so it would floor.
      cap_override(user, "note_points_cap", 1)

      assert :ok =
               perform_job(RebuildStaleNote, %{
                 "note_id" => note.id,
                 "user_id" => user.id,
                 "recap" => true
               })

      assert Enum.map(rows_for(note), & &1.qdrant_point_id) == ids
      assert reload(note).index_tier == nil
    end
  end

  # Review L3 and M4: a recap is unmetered maintenance, so its jobs carry
  # `budget_points` and count against the user's 2,000-a-day ceiling, and
  # both 04:00 sweeps stop at a global maintenance-token ceiling a day.
  describe "maintenance ceilings" do
    defp reverify_tick, do: DateTime.new!(Date.utc_today(), ~T[04:02:00])

    defp recap_jobs, do: for(j <- all_enqueued(worker: RebuildStaleNote), j.args["recap"], do: j)

    test "recap jobs carry budget_points and stop at the daily ceiling", %{
      user: user,
      vault: vault
    } do
      # 20 dense notes of 200 chunks: over the 128 cap, 128 points each.
      full_notes(user, vault, 20, 200)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      jobs = recap_jobs()
      assert jobs != []
      assert Enum.all?(jobs, &(&1.args["budget_points"] == 128 and &1.args["unmetered"]))
      assert jobs |> Enum.map(& &1.args["budget_points"]) |> Enum.sum() <= 2_000
    end

    test "nothing is queued past the global maintenance-token ceiling", %{
      user: user,
      vault: vault
    } do
      prev = Application.get_env(:engram, :maintenance_tokens_per_day)
      Application.put_env(:engram, :maintenance_tokens_per_day, 0)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :maintenance_tokens_per_day),
          else: Application.put_env(:engram, :maintenance_tokens_per_day, prev)
      end)

      full_notes(user, vault, 3, 200)
      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      assert recap_jobs() == []
    end
  end

  describe "review fixes" do
    test "users with nothing promotable never crowd out one that can promote", %{vault: vault} do
      # 24 Free users whose merged notes still exceed the 128 per-note cap,
      # and the user ranked last by id with a floor note: one tick.
      users =
        for _ <- 1..25 do
          {:ok, u} = Crypto.ensure_user_dek(insert(:user))
          {u, insert(:vault, user: u, is_default: true)}
        end
        |> Enum.sort_by(fn {u, _} -> u.id end)

      _ = vault
      {stuck, [{last, last_vault}]} = Enum.split(users, 24)

      for {u, v} <- stuck do
        [merged] = full_notes(u, v, 1, 0)
        seed_rows!(u, v, [merged], 60, token_count: nil, context_hmac: "h", char_end: 1)
        stamp!(u, [merged], chunk_count: 500)
      end

      [floor] = floor_notes(last, last_vault, 1, "floor", 1, chunk_count: 3)

      assert {:ok, %{promoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
      assert [job] = budget_jobs(key: "index_budget", value: "promote")
      assert job.args["note_id"] == floor
    end

    test "a refused floor write leaves the old index and tier", %{
      user: user,
      vault: vault,
      qdrant: qdrant
    } do
      note = dense_note(user, vault)
      old_rows = rows_for(note)
      stamp!(user, [note.id], index_tier: "floor_paid")
      qdrant_set(qdrant, refuse: :upsert, writes: [])

      assert {:error, _} = perform_job(RebuildStaleNote, demote_args(note))
      assert rows_for(note) == old_rows
      assert reload(note).index_tier == "floor_paid"
      assert writes(qdrant, :delete) == []
    end

    test "a refused delete leaves floor and old points; the retry finishes", %{
      user: user,
      vault: vault,
      qdrant: qdrant
    } do
      note = dense_note(user, vault)
      old_ids = Enum.map(rows_for(note), & &1.qdrant_point_id)
      stamp!(user, [note.id], index_tier: "floor_paid")
      qdrant_set(qdrant, refuse: :delete, writes: [])

      assert {:error, _} = perform_job(RebuildStaleNote, demote_args(note))
      assert [%{token_count: nil, qdrant_point_id: floor_id}] = rows_for(note)
      # The floor point was written before any delete was asked for.
      assert [:upsert, :delete] =
               for({kind, _} <- Agent.get(qdrant, & &1.writes), kind != :other, do: kind)

      qdrant_set(qdrant, refuse: nil, writes: [])
      assert :ok = perform_job(RebuildStaleNote, demote_args(note))
      assert [%{token_count: nil, qdrant_point_id: new_floor}] = rows_for(note)

      [by_id, by_path] = writes(qdrant, :delete)
      assert by_id["points"] == [floor_id]
      assert by_path["filter"]["must_not"] == [%{"has_id" => [new_floor]}]
      refute new_floor in old_ids
    end

    test "only a recent pass stamp keeps a note from demotion", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "index_points_cap", value: %{"v" => 3})
      [old, _new] = full_notes(user, vault, 2, 2)

      stamp!(user, [old], embed_started_at: DateTime.utc_now())
      assert {:ok, %{demoted: 0}} = ReconcileEmbeddings.budget_sweep(20)

      stamp!(user, [old], embed_started_at: DateTime.add(DateTime.utc_now(), -3_600, :second))
      assert {:ok, %{demoted: 1}} = ReconcileEmbeddings.budget_sweep(20)
      assert tiers(user, [old]) == %{old => "floor_paid"}
    end
  end

  defp dense_note(user, vault) do
    stub_embedder()
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Five.md", content: @content})
    assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
    assert length(rows_for(note)) == 5
    reload(note)
  end

  defp demote_args(note),
    do: %{"note_id" => note.id, "user_id" => note.user_id, "index_budget" => "demote"}
end
