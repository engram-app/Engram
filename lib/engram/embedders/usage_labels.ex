defmodule Engram.Embedders.UsageLabels do
  @moduledoc """
  The closed-enum labels an embed call's token telemetry carries:

    * `tier`: `:free | :paid`, the owner's plan class.
    * `trigger`: `:edit | :rebuild | :upgrade | :retry | :reconcile`, why the
      indexing pass ran.

  `Engram.Indexing` scopes them around a pass; the Voyage adapter reads them
  where the billed tokens are known. They ride the process, not the embedder
  options, because `Engram.Embedder.embed_texts/2` is optional and a custom
  embedder must not see keys it never asked for. Outside a pass (search
  queries) both read `:none`. Never per-tenant: no user or note ids here.
  """

  @tiers [:free, :paid]
  @triggers [:edit, :rebuild, :upgrade, :retry, :reconcile]
  @key {__MODULE__, :labels}

  @type t :: %{tier: :free | :paid | :none, trigger: atom()}

  @doc "Runs `fun` with `tier` and `trigger` labelled; anything outside the enums reads `:none`."
  @spec with_labels(term(), term(), (-> result)) :: result when result: var
  def with_labels(tier, trigger, fun) do
    prev = Process.put(@key, %{tier: pick(tier, @tiers), trigger: pick(trigger, @triggers)})

    try do
      fun.()
    after
      if prev, do: Process.put(@key, prev), else: Process.delete(@key)
    end
  end

  @spec current() :: t()
  def current, do: Process.get(@key, %{tier: :none, trigger: :none})

  defp pick(value, allowed), do: if(value in allowed, do: value, else: :none)
end
