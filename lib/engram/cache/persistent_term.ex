defmodule Engram.Cache.PersistentTerm do
  @moduledoc """
  Shared scaffolding for the `:persistent_term` caches (a `use` macro):
  read-through memoization of rarely-changing global data, keyed under a
  `{__MODULE__, subkey}` namespace. `:persistent_term` reads are lock-free
  with zero copying; the expensive global rebuild on write only happens on a
  cold miss.

  Injects `pt_fetch/2` (read-through), `pt_erase/1` (drop one subkey), and
  `pt_erase_all/0` (drop every entry under the module's namespace, this node
  only). Invalidation semantics — whether an erase also broadcasts to peer
  nodes — stay in the cache module.
  """

  defmacro __using__(_opts) do
    quote do
      @doc false
      def pt_fetch(subkey, loader) do
        key = {__MODULE__, subkey}

        case :persistent_term.get(key, :__miss__) do
          :__miss__ ->
            loaded = loader.()
            :persistent_term.put(key, loaded)
            loaded

          cached ->
            cached
        end
      end

      @doc false
      def pt_erase(subkey) do
        _ = :persistent_term.erase({__MODULE__, subkey})
        :ok
      end

      @doc false
      def pt_erase_all do
        for {{__MODULE__, _} = k, _v} <- :persistent_term.get() do
          :persistent_term.erase(k)
        end

        :ok
      end
    end
  end
end
