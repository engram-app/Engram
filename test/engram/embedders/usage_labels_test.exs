defmodule Engram.Embedders.UsageLabelsTest do
  use ExUnit.Case, async: true

  alias Engram.Embedders.UsageLabels

  @none %{tier: :none, trigger: :none}

  test "labels are cleared after the block raises" do
    assert_raise RuntimeError, fn ->
      UsageLabels.with_labels(:free, :edit, fn -> raise "boom" end)
    end

    assert UsageLabels.current() == @none
  end

  test "nesting restores the outer labels" do
    UsageLabels.with_labels(:free, :edit, fn ->
      UsageLabels.with_labels(:paid, :retry, fn ->
        assert UsageLabels.current() == %{tier: :paid, trigger: :retry}
      end)

      assert UsageLabels.current() == %{tier: :free, trigger: :edit}
    end)

    assert UsageLabels.current() == @none
  end

  test "values outside the enums read :none" do
    UsageLabels.with_labels(:gold, "x", fn -> assert UsageLabels.current() == @none end)
  end
end
