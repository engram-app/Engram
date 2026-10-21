defmodule Engram.FreeLiteDocEmbedsTest do
  @moduledoc """
  Free notes embed with voyage-4-lite ahead of the v5 umbrella: the doc model
  follows the owner's plan (`Engram.EmbedModels`, copied from
  feat/chunker-v5) only with `EMBED_MODELS_PER_PLAN=true` and billing on.
  Unset, every plan keeps today's one model. The same switch moves paid
  QUERIES to voyage-4-large (`SearchProfile`); Free queries stay lite.

  async: false: flips the global `:billing_enabled` / `:embed_model` /
  `:embed_models_per_plan` env.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.DataMigrations.IndexVersions
  alias Engram.EmbedModels
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.QdrantStub
  alias Engram.Search
  alias Engram.Search.SearchProfile
  alias Engram.UsageMeters
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  @lite "voyage-4-lite"
  @large "voyage-4-large"
  @path "Health/Iron Panel.md"

  setup do
    prev =
      Map.new(
        [:billing_enabled, :embed_model, :embed_models_per_plan, :query_embed_model],
        &{&1, Application.get_env(:engram, &1)}
      )

    on_exit(fn ->
      for {k, v} <- prev,
          do:
            if(v == nil,
              do: Application.delete_env(:engram, k),
              else: Application.put_env(:engram, k, v)
            )
    end)

    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    :ok
  end

  defp saas! do
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :embed_model, @large)
    Application.put_env(:engram, :embed_models_per_plan, true)
  end

  defp self_host! do
    Application.put_env(:engram, :billing_enabled, false)
    Application.put_env(:engram, :embed_model, "nomic-embed-text")
  end

  defp free_user do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    user
  end

  defp paid_user(tier \\ "pro") do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    insert(:subscription, user: user, tier: tier, status: "active")
    Engram.Accounts.get_user_with_subscription!(user.id)
  end

  defp indexed_note(user, model) do
    insert(:note,
      user: user,
      vault: insert(:vault, user: user),
      content_hash: "h1",
      embed_hash: "h1",
      dense_indexed_hash: "h1",
      chunker_version: Markdown.chunker_version(),
      embed_model: model
    )
  end

  defp content(ferritin, transferrin? \\ true) do
    """
    # Iron Panel

    Intro paragraph about the iron panel.

    ## Ferritin

    #{ferritin}
    """ <>
      if transferrin?,
        do: "\n## Transferrin\n\nTransferrin saturation is normal.\n",
        else: ""
  end

  defp put_note(user, vault, body) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => @path, "content" => body, "mtime" => 1_000.0},
        actor: "api"
      )

    note
  end

  defp reload(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  defp point_ids(note) do
    Repo.all(
      from(c in Chunk,
        where: c.note_id == ^note.id and not is_nil(c.qdrant_point_id),
        select: c.qdrant_point_id
      ),
      skip_tenant_check: true
    )
  end

  defp vectors(texts), do: {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}

  # The model each embed call named (`:default` = the global model, the
  # 1-arity call), with its texts.
  defp record_embeds(test_pid) do
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:embedded, :default, texts})
      vectors(texts)
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts, opts ->
      send(test_pid, {:embedded, Keyword.fetch!(opts, :model), texts})
      vectors(texts)
    end)
  end

  defp embeds do
    receive do
      {:embedded, model, texts} -> [{model, texts} | embeds()]
    after
      0 -> []
    end
  end

  defp drain_bucket(user) do
    left = UsageMeters.bucket_available(user.id, 6_000_000)
    {:ok, _} = UsageMeters.bucket_take(user.id, left, 6_000_000)
  end

  describe "the plan picks the doc model" do
    setup do: saas!()

    test "Free embeds with lite, Starter and Pro with large" do
      assert EmbedModels.doc_model(free_user()) == @lite

      for tier <- ["starter", "pro"],
          do: assert(EmbedModels.doc_model(paid_user(tier)) == @large)
    end

    test "acceptable/1: Free keeps lite or large, paid needs large" do
      assert Enum.sort(EmbedModels.acceptable(:free)) == [@large, @lite]
      assert EmbedModels.acceptable(:paid) == [@large]
    end

    test "a Free note embeds with lite and is stamped lite" do
      user = free_user()
      note = put_note(user, insert(:vault, user: user), content("Ferritin levels are low."))
      record_embeds(self())

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      sent = embeds()
      assert sent != []
      assert Enum.all?(sent, fn {model, _} -> model == @lite end)
      assert %Note{embed_model: @lite} = reload(note)
    end

    test "a paid note embeds with large and is stamped large" do
      user = paid_user()
      note = put_note(user, insert(:vault, user: user), content("Ferritin levels are low."))
      record_embeds(self())

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      sent = embeds()
      assert sent != []
      assert Enum.all?(sent, fn {model, _} -> model == @large end)
      assert %Note{embed_model: @large} = reload(note)
    end

    # The bucket meters tokens sent, whatever the model: lite is cheaper for
    # us, not a bigger allowance for the user.
    test "the Free bucket is debited the tokens sent, as before" do
      user = free_user()
      note = put_note(user, insert(:vault, user: user), content("Ferritin levels are low."))
      record_embeds(self())
      before = UsageMeters.lifetime_embed_tokens(user.id)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      bytes = embeds() |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(&byte_size/1) |> Enum.sum()
      assert bytes > 0

      assert UsageMeters.lifetime_embed_tokens(user.id) - before ==
               UsageMeters.estimate_tokens(bytes)
    end

    test "a spent Free bucket still indexes sparse-only, with no model stamped" do
      user = free_user()
      note = put_note(user, insert(:vault, user: user), content("Ferritin levels are low."))
      drain_bucket(user)
      record_embeds(self())

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert embeds() == []
      reloaded = reload(note)
      assert reloaded.embed_hash == note.content_hash
      assert reloaded.dense_indexed_hash == nil
      assert reloaded.embed_model == nil
      assert point_ids(note) != []
    end
  end

  # A Free note indexed with large before the switch: its unchanged chunks
  # keep their large vectors (one embedding space), only new chunks pay lite.
  describe "a Free note indexed with large before the switch" do
    setup do
      saas!()
      Application.put_env(:engram, :embed_models_per_plan, false)
      user = free_user()
      vault = insert(:vault, user: user)
      note = put_note(user, vault, content("Ferritin levels are low."))
      record_embeds(self())
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      assert [{:default, _}] = embeds()
      assert %Note{embed_model: @large} = reload(note)

      Application.put_env(:engram, :embed_models_per_plan, true)
      %{user: user, vault: vault, note: note, ids: point_ids(note)}
    end

    test "an edit embeds only the changed chunk, with lite, and stamps lite", ctx do
      put_note(ctx.user, ctx.vault, content("Ferritin recovered to 90 ng/mL."))

      assert :ok = perform_job(EmbedNote, %{note_id: ctx.note.id})

      assert [{@lite, texts}] = embeds()
      assert texts != []
      assert Enum.all?(texts, &(&1 =~ "Ferritin recovered"))
      assert %Note{embed_model: @lite} = reload(ctx.note)
      kept = MapSet.intersection(MapSet.new(ctx.ids), MapSet.new(point_ids(ctx.note)))
      assert MapSet.size(kept) == length(ctx.ids) - 1
    end

    test "a pass that keeps only large vectors stays stamped large", ctx do
      put_note(ctx.user, ctx.vault, content("Ferritin levels are low.", false))

      assert :ok = perform_job(EmbedNote, %{note_id: ctx.note.id})

      assert embeds() == []
      assert %Note{embed_model: @large} = reload(ctx.note)
    end

    test "a spent bucket keeps every unchanged large vector", ctx do
      drain_bucket(ctx.user)
      put_note(ctx.user, ctx.vault, content("Ferritin recovered to 90 ng/mL."))

      assert :ok = perform_job(EmbedNote, %{note_id: ctx.note.id})

      assert embeds() == []
      kept = MapSet.intersection(MapSet.new(ctx.ids), MapSet.new(point_ids(ctx.note)))
      assert MapSet.size(kept) == length(ctx.ids) - 1
    end
  end

  describe "staleness per plan" do
    setup do: saas!()

    test "Free keeps lite or large; paid re-embeds lite" do
      free = free_user()
      paid = paid_user()

      refute EmbedNote.version_stale?(indexed_note(free, @large))
      refute EmbedNote.version_stale?(indexed_note(free, @lite))
      refute EmbedNote.version_stale?(indexed_note(paid, @large))

      upgraded = indexed_note(paid, @lite)
      assert EmbedNote.version_stale?(upgraded)
      assert EmbedNote.version_stale?(upgraded, true)
      refute EmbedNote.version_stale?(upgraded, false)
    end

    test "the SQL model term agrees with version_stale?/2" do
      free = free_user()
      paid = paid_user()

      notes = [
        indexed_note(free, @large),
        indexed_note(free, @lite),
        indexed_note(paid, @large),
        indexed_note(paid, @lite),
        indexed_note(free, "voyage-3")
      ]

      sql_stale =
        for user <- [free, paid], reduce: MapSet.new() do
          acc ->
            ids =
              Repo.with_tenant!(user.id, fn ->
                IndexVersions.live_notes()
                |> where(^IndexVersions.stale_dynamic())
                |> select([n], n.id)
                |> Repo.all()
              end)

            MapSet.union(acc, MapSet.new(ids))
        end

      for note <- notes do
        assert MapSet.member?(sql_stale, note.id) == EmbedNote.version_stale?(note),
               "#{note.embed_model} disagrees"
      end
    end
  end

  # The plain deploy: billing on, a nameable model, the switch unset. Prod
  # keeps today's one doc model until EMBED_MODELS_PER_PLAN=true.
  describe "SaaS with EMBED_MODELS_PER_PLAN unset keeps one model" do
    setup do
      saas!()
      Application.delete_env(:engram, :embed_models_per_plan)
    end

    test "every plan gets the build's model" do
      refute EmbedModels.per_plan?()

      for user <- [free_user(), paid_user()] do
        assert EmbedModels.doc_model(user) == @large
        assert EmbedModels.reuse_models(user, @large) == []
      end
    end

    test "a Free note embeds with the global model and is stamped large" do
      user = free_user()
      note = put_note(user, insert(:vault, user: user), content("Ferritin levels are low."))
      record_embeds(self())

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert [{:default, _}] = embeds()
      assert %Note{embed_model: @large} = reload(note)
    end

    test "a lite note is stale for every plan, as before" do
      assert EmbedNote.version_stale?(indexed_note(free_user(), @lite))
      refute EmbedNote.version_stale?(indexed_note(free_user(), @large))
    end
  end

  describe "self-host keeps one configured model" do
    setup do
      self_host!()
      Application.put_env(:engram, :embed_models_per_plan, true)
    end

    test "every plan gets the build's model, even with the switch set" do
      refute EmbedModels.per_plan?()

      for user <- [free_user(), paid_user()],
          do: assert(EmbedModels.doc_model(user) == Indexing.embed_model())
    end

    test "a note embeds with the global model and stamps it" do
      user = free_user()
      note = put_note(user, insert(:vault, user: user), content("Ferritin levels are low."))
      record_embeds(self())

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert [{:default, _}] = embeds()
      assert %Note{embed_model: "nomic-embed-text"} = reload(note)
    end

    test "staleness is the exact model, as before" do
      user = free_user()
      refute EmbedNote.version_stale?(indexed_note(user, "nomic-embed-text"))
      assert EmbedNote.version_stale?(indexed_note(user, @large))
    end
  end

  # Prod sets QUERY_EMBED_MODEL=voyage-4-lite for every plan today.
  describe "the searcher's plan picks the query model" do
    setup do
      saas!()
      Application.put_env(:engram, :query_embed_model, @lite)

      bypass = Bypass.open()
      Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      QdrantStub.stub_retrieve(bypass)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      test_pid = self()

      stub(Engram.MockEmbedder, :embed_texts, fn [_query], opts ->
        send(test_pid, {:query_model, opts[:model]})
        {:ok, [List.duplicate(0.1, 3)]}
      end)

      :ok
    end

    defp search_model(user) do
      assert {:ok, _} = Search.search(user, insert(:vault, user: user), "iron panel")
      assert_received {:query_model, model}
      model
    end

    test "per plan: Free queries with lite, Starter and Pro with large" do
      assert SearchProfile.resolve(free_user()).query_model == @lite
      assert search_model(free_user()) == @lite

      for tier <- ["starter", "pro"] do
        assert SearchProfile.resolve(paid_user(tier)).query_model == @large
        assert search_model(paid_user(tier)) == @large
      end
    end

    test "unset, every plan queries with the global lite model" do
      Application.delete_env(:engram, :embed_models_per_plan)

      for user <- [free_user(), paid_user()] do
        assert SearchProfile.resolve(user).query_model == nil
        assert search_model(user) == @lite
      end
    end

    test "self-host queries with the global model, even with the switch set" do
      Application.put_env(:engram, :billing_enabled, false)
      assert SearchProfile.resolve(paid_user()).query_model == nil
      assert search_model(paid_user()) == @lite
    end

    # No query-vector or result cache on the search path: the same query,
    # back to back, embeds again with each searcher's own model.
    test "the same query is never served across plans" do
      free = free_user()
      paid = paid_user()

      assert Enum.map([free, paid, free, paid], &search_model/1) == [@lite, @large, @lite, @large]
    end

    test "a search_query_model override still wins" do
      user = free_user()
      insert(:user_limit_override, user: user, key: "search_query_model", value: %{"v" => @large})
      assert SearchProfile.resolve(user).query_model == @large
    end
  end

  describe "runtime.exs per-plan env" do
    @vars for p <- ~w(FREE STARTER PRO), k <- ~w(DOC QUERY), do: "#{k}_EMBED_MODEL_#{p}"

    setup do
      prev = Map.new(["EMBED_MODELS_PER_PLAN" | @vars], &{&1, System.get_env(&1)})
      Enum.each(["EMBED_MODELS_PER_PLAN" | @vars], &System.delete_env/1)

      on_exit(fn ->
        for {var, v} <- prev, do: if(v, do: System.put_env(var, v), else: System.delete_env(var))
      end)
    end

    defp read(key),
      do:
        get_in(Config.Reader.read!("config/runtime.exs", env: :test, target: :host), [
          :engram,
          key
        ])

    test "unset configures nothing, and per-plan stays off" do
      assert read(:embed_models_per_plan) == nil
      assert read(:plan_doc_embed_models) == %{}
      assert read(:plan_query_embed_models) == %{}
    end

    test "EMBED_MODELS_PER_PLAN=true and the per-plan vars turn it on" do
      System.put_env("EMBED_MODELS_PER_PLAN", "true")
      System.put_env("DOC_EMBED_MODEL_FREE", " voyage-4-lite ")
      System.put_env("DOC_EMBED_MODEL_STARTER", "  ")
      System.put_env("QUERY_EMBED_MODEL_PRO", "voyage-4-large")

      assert read(:embed_models_per_plan) == true
      assert read(:plan_doc_embed_models) == %{free: "voyage-4-lite"}
      assert read(:plan_query_embed_models) == %{pro: "voyage-4-large"}
    end
  end
end
