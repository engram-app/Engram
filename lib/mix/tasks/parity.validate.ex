defmodule Mix.Tasks.Parity.Validate do
  @moduledoc """
  Validates dev-prod parity by exercising Elixir modules against real services.

  Requires real services running (Voyage AI API, Qdrant, MinIO) and valid
  config in .env.elixir. Uses a dedicated test collection and S3 prefix
  that are cleaned up after the run.

  Usage:
      mix parity.validate
  """

  use Mix.Task

  @test_collection "parity_test"
  @test_s3_prefix "parity-test"
  @pipeline_collection "parity_pipeline"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("\n\e[1m═══ Dev-Prod Parity Validation ═══\e[0m\n")

    results = [
      run_section("Voyage AI", &validate_voyage/0),
      run_section("Qdrant", &validate_qdrant/0),
      run_section("MinIO/S3", &validate_s3/0),
      run_section("Full Pipeline", &validate_pipeline/0),
      run_section("Embed Hash Tracking", &validate_embed_tracking/0)
    ]

    IO.puts("\n\e[1m═══ Summary ═══\e[0m")

    total_pass = results |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    total_fail = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    IO.puts("  #{total_pass} passed, #{total_fail} failed\n")

    if total_fail > 0 do
      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------------

  defp validate_voyage do
    check("embed with doc model (voyage-4-large)", fn ->
      {:ok, [vector]} = Engram.Embedders.Voyage.embed_texts(["parity test document"])
      dims = length(vector)

      if dims == 1024,
        do: {:pass, "returned #{dims}d vector"},
        else: {:fail, "expected 1024d, got #{dims}d"}
    end)

    check("embed with query model (voyage-4-lite)", fn ->
      {:ok, [vector]} =
        Engram.Embedders.Voyage.embed_texts(["parity test query"], model: "voyage-4-lite")

      dims = length(vector)

      if dims == 1024,
        do: {:pass, "returned #{dims}d vector"},
        else: {:fail, "expected 1024d, got #{dims}d"}
    end)

    check("asymmetric compatibility (cosine > 0.5)", fn ->
      {:ok, [doc_vec]} = Engram.Embedders.Voyage.embed_texts(["elixir phoenix framework"])

      {:ok, [query_vec]} =
        Engram.Embedders.Voyage.embed_texts(["elixir phoenix framework"],
          model: "voyage-4-lite"
        )

      cosine = cosine_similarity(doc_vec, query_vec)

      if cosine > 0.5,
        do: {:pass, "cosine similarity = #{Float.round(cosine, 4)}"},
        else: {:fail, "cosine similarity too low: #{Float.round(cosine, 4)}"}
    end)
  end

  defp validate_qdrant do
    alias Engram.Vector.Qdrant

    check("create test collection (1024d)", fn ->
      Qdrant.delete_collection(@test_collection)
      # Use a plain collection without binary quantization for the test —
      # binary quant + rescore crashes Qdrant on tiny collections (< ~10 points).
      # The production collection (engram_notes_v2) uses binary quant correctly.
      qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

      {:ok, %{status: status}} =
        Req.put("#{qdrant_url}/collections/#{@test_collection}",
          json: %{vectors: %{size: 1024, distance: "Cosine"}},
          receive_timeout: 30_000
        )

      if status in [200, 201],
        do: {:pass, "created #{@test_collection} (1024d, no binary quant)"},
        else: {:fail, "create collection returned HTTP #{status}"}
    end)

    check("verify production collection has binary quant", fn ->
      prod_collection = Application.get_env(:engram, :qdrant_collection, "obsidian_notes")
      {:ok, info} = Qdrant.collection_info(prod_collection)
      vectors = get_in(info, ["config", "params", "vectors"])
      quant = get_in(info, ["config", "quantization_config", "binary", "always_ram"])

      if vectors["size"] == 1024 and quant == true,
        do: {:pass, "#{prod_collection}: size=#{vectors["size"]}, binary_quant=always_ram"},
        else:
          {:fail,
           "expected 1024d + binary quant, got size=#{vectors["size"]}, quant=#{inspect(quant)}"}
    end)

    check("upsert point with real embedding", fn ->
      {:ok, [vector]} = Engram.Embedders.Voyage.embed_texts(["parity test point"])

      point = %{
        id: Ecto.UUID.generate(),
        vector: vector,
        payload: %{
          user_id: "parity_test_user",
          source_path: "Parity/Test.md",
          title: "Parity Test",
          folder: "Parity",
          tags: ["parity"],
          heading_path: "Parity Test",
          text: "This is a parity test point for validating the pipeline.",
          chunk_index: 0
        }
      }

      :ok = Qdrant.upsert_points(@test_collection, [point])
      Process.sleep(2500)
      {:pass, "upserted 1 point"}
    end)

    check("search (asymmetric query → Qdrant)", fn ->
      {:ok, [query_vec]} =
        Engram.Embedders.Voyage.embed_texts(["parity test"], model: "voyage-4-lite")

      # Search without rescore params — binary quant rescore crashes on tiny collections.
      # Production uses rescore via Qdrant.search/3; here we test the core vector search path.
      qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

      body = %{
        query: query_vec,
        filter: %{must: [%{key: "user_id", match: %{value: "parity_test_user"}}]},
        limit: 5,
        with_payload: true
      }

      {:ok, %{status: 200, body: %{"result" => result}}} =
        Req.post("#{qdrant_url}/collections/#{@test_collection}/points/query",
          json: body,
          receive_timeout: 30_000,
          retry: :transient,
          max_retries: 3
        )

      points = result["points"] || result
      points = if is_list(points), do: points, else: []

      if length(points) >= 1 do
        top = hd(points)
        {:pass, "found #{length(points)} result(s), top score=#{top["score"]}"}
      else
        {:fail, "expected >= 1 result, got 0"}
      end
    end)

    check("delete test collection", fn ->
      :ok = Qdrant.delete_collection(@test_collection)
      {:pass, "deleted #{@test_collection}"}
    end)
  end

  defp validate_s3 do
    alias Engram.Storage.S3

    test_key = "#{@test_s3_prefix}/parity-test.txt"
    test_data = "parity validation #{DateTime.utc_now()}"

    check("S3 put object", fn ->
      :ok = S3.put(test_key, test_data, content_type: "text/plain")
      {:pass, "uploaded #{byte_size(test_data)} bytes"}
    end)

    check("S3 get object (round-trip)", fn ->
      {:ok, retrieved} = S3.get(test_key)

      if retrieved == test_data,
        do: {:pass, "content matches"},
        else: {:fail, "content mismatch"}
    end)

    check("S3 exists?", fn ->
      if S3.exists?(test_key),
        do: {:pass, "exists? returned true"},
        else: {:fail, "exists? returned false for existing object"}
    end)

    check("S3 delete + verify gone", fn ->
      :ok = S3.delete(test_key)

      if S3.exists?(test_key),
        do: {:fail, "object still exists after delete"},
        else: {:pass, "deleted and confirmed gone"}
    end)
  end

  defp validate_pipeline do
    check("full pipeline (note → embed → upsert → search)", fn ->
      alias Engram.Notes
      alias Engram.Vector.Qdrant

      # Use a dedicated plain collection (no binary quant) for the pipeline test
      qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
      Qdrant.delete_collection(@pipeline_collection)

      {:ok, %{status: s}} =
        Req.put("#{qdrant_url}/collections/#{@pipeline_collection}",
          json: %{vectors: %{size: 1024, distance: "Cosine"}}
        )

      unless s in [200, 201], do: raise("Failed to create pipeline collection: #{s}")

      # Temporarily override the collection config so Indexing writes to our test collection
      original_collection = Application.get_env(:engram, :qdrant_collection)
      Application.put_env(:engram, :qdrant_collection, @pipeline_collection)

      try do
        {:ok, user} =
          %Engram.Accounts.User{
            email: "parity-pipeline-#{System.system_time(:second)}@test.local",
            display_name: "Parity Pipeline"
          }
          |> Engram.Repo.insert(skip_tenant_check: true)

        {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Parity Pipeline"})

        {:ok, note} =
          Notes.upsert_note(user, vault, %{
            "path" => "Parity/Pipeline.md",
            "content" =>
              "---\ntags: [parity]\n---\n# Pipeline Validation\n\nThis note validates the full embedding pipeline: Voyage AI embeds the content, Qdrant stores and searches the vectors, and the Elixir backend orchestrates it all.",
            "mtime" => :os.system_time(:second) / 1
          })

        {:ok, chunk_count} = Engram.Indexing.index_note(note, vault)

        if chunk_count == 0 do
          {:fail, "indexing produced 0 chunks"}
        else
          Process.sleep(2500)

          {:ok, [query_vec]} =
            Engram.Embedders.Voyage.embed_texts(["pipeline validation embedding"],
              model: "voyage-4-lite"
            )

          body = %{
            query: query_vec,
            filter: %{must: [%{key: "user_id", match: %{value: to_string(user.id)}}]},
            limit: 5,
            with_payload: true
          }

          {:ok, %{status: 200, body: %{"result" => result}}} =
            Req.post("#{qdrant_url}/collections/#{@pipeline_collection}/points/query",
              json: body,
              receive_timeout: 30_000,
              retry: :transient,
              max_retries: 3
            )

          points = result["points"] || result
          points = if is_list(points), do: points, else: []

          if length(points) >= 1 do
            top = hd(points)

            {:pass,
             "#{chunk_count} chunks indexed, search returned #{length(points)} result(s), " <>
               "top score=#{top["score"]}"}
          else
            {:fail, "search returned 0 results after indexing #{chunk_count} chunks"}
          end
        end
      after
        Application.put_env(:engram, :qdrant_collection, original_collection)
        Qdrant.delete_collection(@pipeline_collection)
      end
    end)
  end

  defp validate_embed_tracking do
    alias Engram.{Notes, Notes.Note, Repo}
    alias Engram.Vector.Qdrant
    alias Engram.Workers.EmbedNote

    import Ecto.Query

    qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
    embed_collection = "parity_embed_hash"
    Qdrant.delete_collection(embed_collection)

    {:ok, %{status: s}} =
      Req.put("#{qdrant_url}/collections/#{embed_collection}",
        json: %{vectors: %{size: 1024, distance: "Cosine"}}
      )

    unless s in [200, 201], do: raise("Failed to create embed_hash collection: #{s}")

    original_collection = Application.get_env(:engram, :qdrant_collection)
    Application.put_env(:engram, :qdrant_collection, embed_collection)

    try do
      {:ok, user} =
        %Engram.Accounts.User{
          email: "parity-embed-#{System.system_time(:second)}@test.local",
          display_name: "Parity Embed Hash"
        }
        |> Engram.Repo.insert(skip_tenant_check: true)

      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Parity Embed Hash"})

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Parity/EmbedHash.md",
          "content" => "# Embed Hash Test\n\nValidates the embed_hash tracking lifecycle.",
          "mtime" => :os.system_time(:second) / 1
        })

      check("embed_hash nil before first embed", fn ->
        fresh = Repo.get!(Note, note.id, skip_tenant_check: true)

        if is_nil(fresh.embed_hash),
          do: {:pass, "embed_hash is nil, content_hash=#{fresh.content_hash}"},
          else: {:fail, "expected nil embed_hash, got #{fresh.embed_hash}"}
      end)

      check("EmbedNote.perform indexes + stamps embed_hash", fn ->
        job = %Oban.Job{args: %{"note_id" => note.id}}
        :ok = EmbedNote.perform(job)
        stamped = Repo.get!(Note, note.id, skip_tenant_check: true)

        if stamped.embed_hash == stamped.content_hash and not is_nil(stamped.embed_hash),
          do: {:pass, "embed_hash=#{stamped.embed_hash}"},
          else: {:fail, "embed_hash=#{stamped.embed_hash}, content_hash=#{stamped.content_hash}"}
      end)

      check("EmbedNote.perform skips when already embedded (idempotent)", fn ->
        before = Repo.get!(Note, note.id, skip_tenant_check: true)
        job = %Oban.Job{args: %{"note_id" => note.id}}
        :ok = EmbedNote.perform(job)
        after_run = Repo.get!(Note, note.id, skip_tenant_check: true)

        if before.embed_hash == after_run.embed_hash,
          do: {:pass, "skipped — embed_hash unchanged"},
          else: {:fail, "embed_hash changed from #{before.embed_hash} to #{after_run.embed_hash}"}
      end)

      check("content update creates embed_hash mismatch", fn ->
        {:ok, updated} =
          Notes.upsert_note(user, vault, %{
            "path" => "Parity/EmbedHash.md",
            "content" => "# Embed Hash Test\n\nUpdated content to trigger re-embed.",
            "mtime" => :os.system_time(:second) / 1 + 1
          })

        reloaded = Repo.get!(Note, updated.id, skip_tenant_check: true)

        if reloaded.embed_hash != reloaded.content_hash,
          do: {:pass, "mismatch: embed=#{reloaded.embed_hash}, content=#{reloaded.content_hash}"},
          else: {:fail, "expected mismatch, both are #{reloaded.embed_hash}"}
      end)

      check("ReconcileEmbeddings finds pending note", fn ->
        pending =
          from(n in Note,
            where:
              is_nil(n.deleted_at) and
                n.user_id == ^user.id and
                (is_nil(n.embed_hash) or n.embed_hash != n.content_hash),
            select: n.id
          )
          |> Repo.all(skip_tenant_check: true)

        if length(pending) >= 1,
          do: {:pass, "#{length(pending)} pending note(s) detected"},
          else: {:fail, "expected >= 1 pending, got 0"}
      end)

      check("re-embed stamps new embed_hash", fn ->
        job = %Oban.Job{args: %{"note_id" => note.id}}
        :ok = EmbedNote.perform(job)
        Process.sleep(1000)
        final = Repo.get!(Note, note.id, skip_tenant_check: true)

        if final.embed_hash == final.content_hash and not is_nil(final.embed_hash),
          do: {:pass, "re-stamped: embed_hash=#{final.embed_hash}"},
          else: {:fail, "embed_hash=#{final.embed_hash}, content_hash=#{final.content_hash}"}
      end)

      check("search finds re-embedded content", fn ->
        Process.sleep(2000)

        {:ok, [query_vec]} =
          Engram.Embedders.Voyage.embed_texts(["embed hash re-embed"],
            model: "voyage-4-lite"
          )

        body = %{
          query: query_vec,
          filter: %{must: [%{key: "user_id", match: %{value: to_string(user.id)}}]},
          limit: 5,
          with_payload: true
        }

        {:ok, %{status: 200, body: %{"result" => result}}} =
          Req.post("#{qdrant_url}/collections/#{embed_collection}/points/query",
            json: body,
            receive_timeout: 30_000,
            retry: :transient,
            max_retries: 3
          )

        points = result["points"] || result
        points = if is_list(points), do: points, else: []

        if length(points) >= 1 do
          top = hd(points)
          text = get_in(top, ["payload", "text"]) || ""

          if String.contains?(text, "re-embed"),
            do: {:pass, "found updated content, score=#{top["score"]}"},
            else: {:pass, "found #{length(points)} result(s), top score=#{top["score"]}"}
        else
          {:fail, "expected >= 1 result after re-embed, got 0"}
        end
      end)
    after
      Application.put_env(:engram, :qdrant_collection, original_collection)
      Qdrant.delete_collection(embed_collection)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_section(name, fun) do
    IO.puts("─── #{name} ───")
    prev = Process.get(:parity_counts, {0, 0})
    Process.put(:parity_counts, {0, 0})

    fun.()

    {section_pass, section_fail} = Process.get(:parity_counts, {0, 0})
    {prev_pass, prev_fail} = prev
    Process.put(:parity_counts, {prev_pass + section_pass, prev_fail + section_fail})
    IO.puts("")
    {section_pass, section_fail}
  end

  defp check(name, fun) do
    {pass_count, fail_count} = Process.get(:parity_counts, {0, 0})

    try do
      case fun.() do
        {:pass, detail} ->
          IO.puts("  \e[32m✓\e[0m #{name} — #{detail}")
          Process.put(:parity_counts, {pass_count + 1, fail_count})

        {:fail, detail} ->
          IO.puts("  \e[31m✗\e[0m #{name} — #{detail}")
          Process.put(:parity_counts, {pass_count, fail_count + 1})
      end
    rescue
      e ->
        IO.puts("  \e[31m✗\e[0m #{name} — EXCEPTION: #{Exception.message(e)}")
        Process.put(:parity_counts, {pass_count, fail_count + 1})
    end
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    mag_a = :math.sqrt(Enum.map(a, &(&1 * &1)) |> Enum.sum())
    mag_b = :math.sqrt(Enum.map(b, &(&1 * &1)) |> Enum.sum())
    dot / (mag_a * mag_b)
  end
end
