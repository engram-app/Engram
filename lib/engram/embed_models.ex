defmodule Engram.EmbedModels do
  @moduledoc """
  Which Voyage model embeds a note's documents and a user's queries, by plan
  (chunker v5 rebuild, "model per plan").

  SaaS (`:billing_enabled`): Free embeds documents AND queries with
  `voyage-4-lite`, Starter and Pro with `voyage-4-large`. The voyage-4 family
  shares one embedding space, so lite and large points coexist in one
  collection and either query model searches both (workspace report
  `reports/2026-10-19-rechunk-once/multilingual-model-quality.md`).

    * The DOC model follows the note OWNER's plan at embed time (ordinary
      embeds and the rebuild) and is stamped on `notes.embed_model`. Every
      reuse path (the vector cache, the chunk fingerprints and so the
      rebuild's copied and mean-pooled vectors, the dry-run estimate) takes a
      vector made by that model or a higher tier of the family
      (`reuse_models/2`), never a lower one. A kept vector's fingerprint
      still names the model that made it.
    * The QUERY model follows the SEARCHING user's plan
      (`Engram.Search.SearchProfile`); a `search_query_model` override wins.

  ## Plan changes re-embed nothing by themselves

    * Upgrade: the note's next edit embeds with the new model. A note left
      unedited is found by the reconcile sweep's model term and queued as a
      `RebuildStaleNote` at the lowest priority (`upgrade: true`), paced by
      the rebuild's gate (maintenance token bucket and Qdrant health) even
      when the pass is not `on`, and its Voyage tokens debit that bucket
      (`Rebuild.paced/1`).
    * Downgrade: the large vectors stay (`acceptable/1` takes any plan model
      priced at least as high as the one the plan needs). A later pass,
      including the rebuild, keeps every stored large vector
      (`reuse_models/2`) and embeds only new or changed chunks at lite.

  Self-host (billing off), and any build that cannot name its model (the
  test mock): one configured model for every note and query, as before
  (`Engram.Indexing.embed_model/0`, `:query_embed_model`).

  ## Prices

  `price/1` is micro-USD per million tokens, from Voyage's public pricing
  page (https://docs.voyageai.com/docs/pricing, read 2026-10-21):
  voyage-4-large $0.12/M, voyage-4-lite $0.02/M. `:voyage_prices`
  overrides them. The rebuild ledger counts cost in voyage-4-large tokens
  (`large_tokens/2`): a lite token debits 1/6 of one.
  """

  alias Engram.Billing
  alias Engram.Indexing

  @plan_defaults %{free: "voyage-4-lite", starter: "voyage-4-large", pro: "voyage-4-large"}
  @large "voyage-4-large"
  @prices %{"voyage-4-large" => 120_000, "voyage-4-lite" => 20_000}

  @type tier :: :free | :starter | :pro

  @doc "The per-plan defaults; an unset env var reads these (runtime.exs)."
  def plan_defaults, do: @plan_defaults

  @doc "True when models follow the plan: billing on and a nameable model."
  @spec per_plan?() :: boolean()
  def per_plan?,
    do:
      Application.get_env(:engram, :billing_enabled, false) == true and
        Indexing.embed_model() != nil

  @doc "The model a pass embeds `user`'s documents with."
  @spec doc_model(Engram.Accounts.User.t()) :: String.t() | nil
  def doc_model(user) do
    if per_plan?(),
      do: plan_model(:plan_doc_embed_models, Billing.tier(user)),
      else: Indexing.embed_model()
  end

  @doc "The query model for `user`'s plan; nil off per-plan (the global one applies)."
  @spec query_model(Engram.Accounts.User.t()) :: String.t() | nil
  def query_model(user) do
    if per_plan?(), do: plan_model(:plan_query_embed_models, Billing.tier(user))
  end

  @doc """
  Doc models a note of a `:free` or `:paid` owner may keep without a
  re-embed: its plan's, or any plan model priced at least as high (a
  downgrade keeps large vectors). A paid owner needs the cheaper of the
  Starter and Pro models, so neither paid plan loops.
  """
  @spec acceptable(:free | :paid) :: [String.t()]
  def acceptable(class) do
    models = Map.values(plan_models(:plan_doc_embed_models))

    floor =
      case class do
        :free ->
          price(plan_model(:plan_doc_embed_models, :free))

        :paid ->
          min(
            price(plan_model(:plan_doc_embed_models, :starter)),
            price(plan_model(:plan_doc_embed_models, :pro))
          )
      end

    models |> Enum.filter(&(price(&1) >= floor)) |> Enum.uniq()
  end

  @doc """
  Models other than `model` whose STORED vectors `user`'s notes may keep: the
  higher tiers of the family (`acceptable/1` for the owner's plan), most
  expensive first. A Free pass keeps a large vector and embeds only new or
  changed chunks with lite; a paid pass keeps nothing made by lite. [] off
  per-plan.
  """
  @spec reuse_models(Engram.Accounts.User.t(), String.t() | nil) :: [String.t()]
  def reuse_models(user, model) do
    if per_plan?() do
      class = if Billing.paid?(user), do: :paid, else: :free

      class
      |> acceptable()
      |> Enum.reject(&(&1 == model))
      |> Enum.sort_by(&price/1, :desc)
    else
      []
    end
  end

  @doc "Micro-USD per million tokens; an unknown model prices as voyage-4-large."
  @spec price(String.t() | nil) :: pos_integer()
  def price(model) do
    prices = Application.get_env(:engram, :voyage_prices, @prices)
    Map.get(prices, model) || Map.get(prices, @large) || Map.fetch!(@prices, @large)
  end

  @doc "`tokens` of `model` as voyage-4-large tokens of equal cost, rounded up."
  @spec large_tokens(non_neg_integer(), String.t() | nil) :: non_neg_integer()
  def large_tokens(tokens, model) do
    large = price(@large)
    div(tokens * price(model) + large - 1, large)
  end

  defp plan_models(key), do: Map.merge(@plan_defaults, Application.get_env(:engram, key, %{}))

  defp plan_model(key, tier), do: Map.fetch!(plan_models(key), tier)
end
