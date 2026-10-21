defmodule Engram.EmbedModelsTest do
  @moduledoc """
  Model per plan (v5 rebuild): Free voyage-4-lite, paid voyage-4-large, for
  documents and queries; a plan change re-embeds nothing by itself.

  async: false: flips the global `:billing_enabled` / `:embed_model` env and
  runs the reconcile cron.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.EmbedModels
  alias Engram.Indexing
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild
  alias Engram.Rebuild.Manifest
  alias Engram.Search.SearchProfile
  alias Engram.ServiceConfig
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings}

  @lite "voyage-4-lite"
  @large "voyage-4-large"

  setup do
    prev =
      Map.new(
        [:billing_enabled, :embed_model, :embed_models_per_plan],
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

    DataMigrations.reset_cache()
    Engram.Cache.clear_local(:rebuild)
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

  defp free_user, do: insert(:user)

  defp paid_user(tier \\ "pro") do
    user = insert(:user)
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

  describe "SaaS: the plan picks the model" do
    setup do: saas!()

    test "Free embeds and searches with lite, Starter and Pro with large" do
      free = free_user()
      assert EmbedModels.doc_model(free) == @lite
      assert EmbedModels.query_model(free) == @lite

      for tier <- ["starter", "pro"] do
        paid = paid_user(tier)
        assert EmbedModels.doc_model(paid) == @large
        assert EmbedModels.query_model(paid) == @large
      end
    end

    test "the search profile follows the searching user's plan" do
      assert SearchProfile.resolve(free_user()).query_model == @lite
      assert SearchProfile.resolve(paid_user()).query_model == @large
    end

    test "a downgrade keeps large vectors; an upgrade is model-only stale" do
      free = free_user()
      paid = paid_user()

      refute EmbedNote.version_stale?(indexed_note(free, @large))
      refute EmbedNote.version_stale?(indexed_note(free, @lite))
      refute EmbedNote.version_stale?(indexed_note(paid, @large))

      upgraded = indexed_note(paid, @lite)
      assert EmbedNote.version_stale?(upgraded)
      assert EmbedNote.model_only_stale?(upgraded)
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

    test "an unedited upgraded note is queued as a paced, lowest-priority rebuild" do
      note = indexed_note(paid_user(), @lite)
      kept = indexed_note(free_user(), @large)

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      assert_enqueued(
        worker: RebuildStaleNote,
        args: %{"note_id" => note.id, "upgrade" => true},
        priority: EmbedNote.backfill_priority()
      )

      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => kept.id})
    end

    test "the dry run records the plan model and the seal prices lite at a sixth" do
      ServiceConfig.put_override(:write_v5_layout, true)
      ServiceConfig.put_override(:index_rebuild, "dry_run")
      Repo.query!("DELETE FROM rebuild_ledger")

      free = free_user()
      paid = paid_user()

      for {user, tokens} <- [{free, 6_000}, {paid, 6_000}] do
        vault = insert(:vault, user: user)
        note = insert(:note, user: user, vault: vault)

        Rebuild.put_manifest(user.id, [
          %{
            note_id: note.id,
            vault_id: vault.id,
            model: EmbedModels.doc_model(user),
            est_tokens: tokens,
            new_points: 1,
            reused_points: 0,
            mean_pooled_points: 0,
            dl_sum: 0,
            dl_count: 0
          }
        ])
      end

      assert [@lite] =
               Repo.with_tenant!(free.id, fn -> Repo.all(from m in Manifest, select: m.model) end)

      # (1,000 + 6,000) large-equivalent tokens, times 1.15.
      assert {:ok, 8_050} = Rebuild.seal()
    end

    test "a rebuild debits lite tokens at a sixth of large" do
      Repo.query!("DELETE FROM rebuild_ledger")
      Rebuild.set_budget(1_000_000)
      user = free_user()
      note = %Note{id: Ecto.UUID.generate(), user_id: user.id}

      Rebuild.spend(note, fn ->
        :telemetry.execute([:engram, :voyage, :embed, :tokens], %{total_tokens: 600}, %{
          purpose: :maintenance,
          model: @lite
        })

        :telemetry.execute([:engram, :voyage, :embed, :tokens], %{total_tokens: 600}, %{
          purpose: :maintenance,
          model: @large
        })
      end)

      assert Rebuild.ledger().spent_tokens == 700
    end
  end

  describe "upgrade pacing" do
    setup do
      saas!()
      EngramWeb.RateLimiter.reset_buckets!()
      ServiceConfig.put_override(:index_rebuild, "off")
      :ok
    end

    test "an upgrade re-embed charges the maintenance bucket; the next one in a spent minute snoozes" do
      Rebuild.paced(fn ->
        :telemetry.execute([:engram, :voyage, :embed, :tokens], %{total_tokens: 150_000}, %{
          purpose: :maintenance,
          model: @large
        })
      end)

      note = indexed_note(paid_user(), @lite)

      assert {:snooze, 30} =
               perform_job(RebuildStaleNote, %{
                 note_id: note.id,
                 user_id: note.user_id,
                 upgrade: true
               })
    end

    test "paced/1 returns its function's result" do
      :telemetry.execute([:engram, :voyage, :embed, :tokens], %{total_tokens: 150_000}, %{
        purpose: :maintenance,
        model: @large
      })

      assert Rebuild.paced(fn -> :ran end) == :ran
    end
  end

  # The plain deploy: billing on, a nameable model, the switch unset. Prod
  # must keep today's one doc model and one query model until v5 go time.
  describe "SaaS with EMBED_MODELS_PER_PLAN unset keeps one model" do
    setup do
      saas!()
      Application.delete_env(:engram, :embed_models_per_plan)
    end

    test "every plan gets the build's model and no per-plan query model" do
      refute EmbedModels.per_plan?()

      for user <- [free_user(), paid_user()] do
        assert EmbedModels.doc_model(user) == @large
        assert EmbedModels.query_model(user) == nil
        assert EmbedModels.reuse_models(user, @large) == []
      end
    end

    test "a large-model note is current for a Free owner and a paid one" do
      refute EmbedNote.version_stale?(indexed_note(free_user(), @large))
      refute EmbedNote.version_stale?(indexed_note(paid_user(), @large))
    end
  end

  describe "self-host keeps one configured model" do
    setup do: self_host!()

    test "every plan gets the build's model and no per-plan query model" do
      for user <- [free_user(), paid_user()] do
        assert EmbedModels.doc_model(user) == Indexing.embed_model()
        assert EmbedModels.query_model(user) == nil
      end

      refute EmbedModels.per_plan?()
    end

    test "staleness is the exact model, as before" do
      user = free_user()
      refute EmbedNote.version_stale?(indexed_note(user, "nomic-embed-text"))
      assert EmbedNote.version_stale?(indexed_note(user, @large))
    end
  end

  describe "pricing" do
    test "Voyage list prices per million tokens; unknown prices as large" do
      assert EmbedModels.price(@large) == 120_000
      assert EmbedModels.price(@lite) == 20_000
      assert EmbedModels.price("something-new") == 120_000
      assert EmbedModels.price(nil) == 120_000
    end

    test "large_tokens/2 rounds up and is exact for large" do
      assert EmbedModels.large_tokens(600, @lite) == 100
      assert EmbedModels.large_tokens(1, @lite) == 1
      assert EmbedModels.large_tokens(0, @lite) == 0
      assert EmbedModels.large_tokens(600, @large) == 600
    end

    test "acceptable/1: Free keeps lite or large, paid needs large" do
      saas!()
      assert Enum.sort(EmbedModels.acceptable(:free)) == [@large, @lite]
      assert EmbedModels.acceptable(:paid) == [@large]
    end
  end

  describe "runtime.exs per-plan env" do
    @vars for p <- ~w(FREE STARTER PRO), k <- ~w(DOC QUERY), do: "#{k}_EMBED_MODEL_#{p}"

    setup do
      prev = Map.new(@vars, &{&1, System.get_env(&1)})
      Enum.each(@vars, &System.delete_env/1)

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

    test "unset equals the defaults, and per-plan stays off" do
      System.delete_env("EMBED_MODELS_PER_PLAN")
      assert read(:embed_models_per_plan) == nil
      # Nothing configured: `EmbedModels` holds the one copy of the defaults.
      assert read(:plan_doc_embed_models) == %{}
      assert read(:plan_query_embed_models) == %{}
    end

    test "EMBED_MODELS_PER_PLAN=true turns it on" do
      prev = System.get_env("EMBED_MODELS_PER_PLAN")
      System.put_env("EMBED_MODELS_PER_PLAN", "true")

      on_exit(fn ->
        if prev,
          do: System.put_env("EMBED_MODELS_PER_PLAN", prev),
          else: System.delete_env("EMBED_MODELS_PER_PLAN")
      end)

      assert read(:embed_models_per_plan) == true
    end

    test "each plan reads its own var; blank is the default" do
      System.put_env("QUERY_EMBED_MODEL_FREE", " voyage-4 ")
      System.put_env("DOC_EMBED_MODEL_PRO", "voyage-context-4")
      System.put_env("DOC_EMBED_MODEL_STARTER", "  ")

      assert read(:plan_query_embed_models) == %{free: "voyage-4"}
      assert read(:plan_doc_embed_models) == %{pro: "voyage-context-4"}
    end
  end
end
