defmodule Engram.Search do
  @moduledoc """
  Two-stage search: embed query → Qdrant similarity (4x candidates) →
  reranker (blend scores) → return top N results.

  Both embedder and reranker are config-driven behaviours:
  - `:embedder`  — Engram.Embedders.Voyage | .Ollama | any Engram.Embedder impl
  - `:reranker`  — Engram.Rerankers.Jina | .None | any Engram.Reranker impl
  """

  alias Engram.Vector.Qdrant

  @min_candidates 20

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "obsidian_notes")

  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  defp reranker, do: Application.get_env(:engram, :reranker, Engram.Rerankers.None)

  defp reranker_active?, do: reranker() != Engram.Rerankers.None

  defp query_embed_model, do: Application.get_env(:engram, :query_embed_model)

  defp embed_for_search(query) do
    case query_embed_model() do
      nil -> embedder().embed_texts([query])
      model -> embedder().embed_texts([query], model: model)
    end
  end

  @doc """
  Search notes for a user within a vault. Returns {:ok, results} where each result has:
  score, text, title, heading_path, source_path, tags.

  Pass `vault: nil` with `cross_vault: true` in opts to search across all user vaults
  (requires billing feature check).

  Options:
  - `:limit`       — number of results (default 5)
  - `:tags`        — filter to notes with any of these tags
  - `:folder`      — filter to notes in this folder
  - `:cross_vault` — when true, search across all vaults (billing-gated)
  """
  def search(user, vault, query, opts \\ []) do
    cross_vault = Keyword.get(opts, :cross_vault, false)

    if cross_vault do
      case Engram.Billing.check_feature(user, "cross_vault_search") do
        :ok -> do_search(user, nil, query, opts)
        {:error, _} = err -> err
      end
    else
      do_search(user, vault, query, opts)
    end
  end

  defp do_search(user, vault, query, opts) do
    limit = Keyword.get(opts, :limit, 5)
    tags = Keyword.get(opts, :tags)
    folder = Keyword.get(opts, :folder)

    # Fetch more candidates when reranking is active
    fetch_limit = if reranker_active?(), do: max(limit * 4, @min_candidates), else: limit

    case translate_phase_b_filters(user, folder, tags) do
      {:ok, phase_b_kw} ->
        with {:ok, [vector]} <- embed_for_search(query) do
          search_opts =
            [user_id: to_string(user.id), limit: fetch_limit]
            |> then(&if(vault, do: Keyword.put(&1, :vault_id, to_string(vault.id)), else: &1))
            |> Keyword.merge(phase_b_kw)

          with {:ok, candidates} <- Qdrant.search(collection(), vector, search_opts),
               vaults_by_id = load_candidate_vaults(user, vault, candidates),
               {:ok, decrypted} <-
                 Engram.Crypto.decrypt_qdrant_candidates(candidates, user, vaults_by_id) do
            reranker().rerank(query, decrypted, limit)
          end
        end

      :no_dek_with_filter ->
        # Caller asked to filter by folder/tags but has no DEK provisioned —
        # impossible to derive HMAC, and the user has no encrypted points to
        # match anyway. Mirrors list_folders (B.2.2) defensive empty.
        {:ok, []}
    end
  end

  # Returns either {:ok, kw} where kw is the [folder_hmac: ..., tags_hmac: ...]
  # subset to merge into Qdrant search opts, or :no_dek_with_filter when the
  # caller asked for a filter but has no DEK to derive the HMAC. An unfiltered
  # search (no folder, no tags) is always {:ok, []} — DEK not required.
  defp translate_phase_b_filters(_user, nil, nil), do: {:ok, []}

  defp translate_phase_b_filters(user, folder, tags) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        kw =
          []
          |> maybe_put_folder_hmac(filter_key, folder)
          |> maybe_put_tags_hmac(filter_key, tags)

        {:ok, kw}

      {:error, :no_dek} ->
        :no_dek_with_filter
    end
  end

  defp maybe_put_folder_hmac(kw, _filter_key, nil), do: kw

  defp maybe_put_folder_hmac(kw, filter_key, folder),
    do: Keyword.put(kw, :folder_hmac, Base.encode64(Engram.Crypto.hmac_field(filter_key, folder)))

  defp maybe_put_tags_hmac(kw, _filter_key, nil), do: kw

  defp maybe_put_tags_hmac(kw, filter_key, tags) do
    encoded = Enum.map(tags, &Base.encode64(Engram.Crypto.hmac_field(filter_key, &1)))
    Keyword.put(kw, :tags_hmac, encoded)
  end

  # Single-vault search: return the passed-in vault directly — no extra DB query.
  # Cross-vault search (vault=nil): batch-load only the vaults referenced by candidates.
  defp load_candidate_vaults(_user, %Engram.Vaults.Vault{id: id} = v, _candidates),
    do: %{to_string(id) => v}

  defp load_candidate_vaults(user, nil, candidates) do
    vault_ids =
      candidates
      |> Enum.map(&Map.get(&1, :vault_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Engram.Vaults.list_for_ids(user, vault_ids)
  end
end
