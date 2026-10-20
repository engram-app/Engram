defmodule Engram.PromEx.Buckets do
  @moduledoc """
  Compiled Peep bucket calculators for our histograms.

  A distribution without `:peep_bucket_calculator` makes
  `PromEx.MetricTypes.Event.build/2` `Module.create/3` a `<group>.Bucket_N`
  module on every `event_metrics/1` call. Every call after the first is a
  redefinition, and the code server loads a redefinition with a purge that
  checks every process in the VM while answering nothing else. Under load
  that stalled callers of the code server past ExUnit's 60 s timeout.

      defmodule MyBuckets do
        use Engram.PromEx.Buckets, [1, 5, 10]
      end

      reporter_options: Engram.PromEx.Buckets.opts(MyBuckets)

  Pinned by Engram.PromEx.FixedBucketsTest.
  """

  defmacro __using__(buckets) do
    quote do
      use Peep.Buckets.Custom, buckets: unquote(buckets)

      @doc "The `le` boundaries, also passed as `buckets:` for the Core reporter."
      def buckets, do: unquote(buckets)
    end
  end

  @doc "Reporter options naming `mod` as the calculator for its own boundaries."
  def opts(mod), do: [buckets: mod.buckets(), peep_bucket_calculator: mod]
end
