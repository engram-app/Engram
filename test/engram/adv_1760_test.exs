defmodule Engram.Adv1760Test do
  # Adversarial tests for PR #1760 (semantic search for every tier). Each test
  # asserts the behaviour the PR should have and FAILS on the PR as written.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Search
  alias Engram.UsageMeters
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.ReconcileEmbeddings

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)

    {:ok, user} = insert(:user) |> Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  defp stub_qdrant(bypass) do
    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  defp vectors(texts), do: {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}

  # FLAW: the budget gate charges the WHOLE note (estimate_note_tokens of the
  # ciphertext) even though chunk reuse (#1595) makes an edit cost one chunk.
  # A Free user near the cap who fixes a typo gets a sparse-only pass, which
  # (different fingerprint) replaces EVERY dense point with a sparse one: the
  # note silently drops out of semantic search to save tokens it never needed.
  test "a small edit near the cap keeps the note's dense vectors when reuse makes it affordable",
       %{bypass: bypass, user: user, vault: vault} do
    stub_qdrant(bypass)
    stub(Engram.MockEmbedder, :embed_texts, fn texts -> vectors(texts) end)

    body =
      Enum.map_join(1..6, "\n\n", &"## Section #{&1}\n\n#{String.duplicate("word#{&1} ", 200)}")

    note = Engram.Fixtures.insert_note!(user, vault, %{path: "N.md", content: "# N\n\n" <> body})
    assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    first = UsageMeters.lifetime_embed_tokens(user.id)
    assert first > 0

    # Leave half a note of budget: plenty for one re-embedded section (~1/6).
    UsageMeters.add_embed_tokens(user.id, 20_000_000 - first - div(first, 2))

    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "N.md",
        "content" => "# N\n\n" <> String.replace(body, "word3 ", "edited3 ", global: false),
        "mtime" => 2_000.0
      })

    assert :ok = perform_job(EmbedNote, %{note_id: note.id})

    after_edit = Repo.get!(Note, note.id, skip_tenant_check: true)

    assert after_edit.dense_indexed_hash == after_edit.content_hash,
           "one-section edit went sparse-only and dropped every dense vector"
  end

  # FLAW: the gate reads `lifetime_embed_tokens` and only records AFTER Voyage
  # returns, with no reservation. `embed: 5` per node and ReconcileEmbeddings
  # enqueues a Free user's whole 2,000-note backfill at once, so N concurrent
  # jobs each see the same `current` and each pass. Simulated here by running
  # job B while job A is inside its Voyage call.
  test "two in-flight embeds cannot both pass a budget that fits only one",
       %{bypass: bypass, user: user, vault: vault} do
    stub_qdrant(bypass)
    content = "# A\n\n" <> String.duplicate("alpha ", 2_000)
    a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md", content: content})
    b = Engram.Fixtures.insert_note!(user, vault, %{path: "B.md", content: content})

    per_note =
      UsageMeters.estimate_tokens(
        Repo.get!(Note, a.id, skip_tenant_check: true).content_ciphertext
      )

    # Room for one note (x1.5 slack for chunk-prefix overhead), not two.
    UsageMeters.add_embed_tokens(user.id, 20_000_000 - div(per_note * 3, 2))

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      if Process.get(:nested) == nil do
        Process.put(:nested, true)
        :ok = perform_job(EmbedNote, %{note_id: b.id})
      end

      vectors(texts)
    end)

    assert :ok = perform_job(EmbedNote, %{note_id: a.id})

    assert UsageMeters.lifetime_embed_tokens(user.id) <= 20_000_000,
           "lifetime cap overshot: #{UsageMeters.lifetime_embed_tokens(user.id)}"
  end

  # FLAW: park_over_budget/stamp_embed_hash set embed_retry_after 24h out, and
  # ReconcileEmbeddings' cooldown filter applies to the paid-subscription
  # clause too. A Free user who ran out of budget and UPGRADES gets no dense
  # vectors on the parked notes for up to 24h: they pay and search is worse.
  test "an upgrade backfills dense vectors on budget-parked notes without a 24h wait",
       %{user: user, vault: vault} do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "P.md", content: "# P\n\nbody"})
    UsageMeters.add_embed_tokens(user.id, 20_000_000)

    from(n in Note, where: n.id == ^note.id)
    |> Repo.update_all(
      [
        set: [
          embed_hash: note.content_hash,
          dense_indexed_hash: nil,
          chunker_version: Markdown.chunker_version()
        ]
      ],
      skip_tenant_check: true
    )

    # Parks it (no Voyage, no Qdrant).
    assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    parked = Repo.get!(Note, note.id, skip_tenant_check: true)
    assert DateTime.compare(parked.embed_retry_after, DateTime.utc_now()) == :gt

    insert(:subscription, user: user, tier: "pro", status: "active")
    Engram.Billing.OverrideCache.evict(user.id)

    assert :ok = perform_job(ReconcileEmbeddings, %{})
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end

  # FLAW: `suggest_folder` and `auto_place_folder` call Search.search/4 with no
  # :mode, which defaults to :vector (dense only). Before this PR a Free user
  # was clamped to :keyword there. Now every sparse-only note (all Free notes
  # until the backfill drains, and every note edited after the budget is
  # spent, forever) is invisible to them: suggest_folder answers "No folders
  # found. The vault may be empty." and create_note auto-placement falls back
  # to the root folder.
  test "the MCP folder-suggestion search still reaches sparse-only notes",
       %{bypass: bypass, user: user, vault: vault} do
    test_pid = self()
    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts -> vectors(texts) end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_body, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": []}))
    end)

    # The exact opts `suggest_folder` / `auto_place_folder` send.
    assert {:ok, []} = Search.search(user, vault, "iron panel", limit: 10, diversity: 0)
    assert_receive {:qdrant_body, raw}

    assert raw =~ ~s("keyword"),
           "folder suggestion ran dense-only; sparse-only notes are invisible. body=#{raw}"
  end
end
