defmodule EngramWeb.Assets.MarketingCSSTest do
  use ExUnit.Case, async: true

  @moduletag :assets

  @compiled_path "priv/static/css/marketing.css"

  describe "marketing CSS build reproducibility" do
    @tag timeout: 120_000
    test "committed CSS matches fresh Tailwind rebuild" do
      committed = File.read!(@compiled_path)

      {output, 0} = System.cmd("mix", ["tailwind", "marketing"], stderr_to_stdout: true)
      assert output =~ "Done in"

      rebuilt = File.read!(@compiled_path)

      assert committed == rebuilt,
             "priv/static/css/marketing.css is stale. " <>
               "Run `mix tailwind marketing` and commit the result."
    end

    test "marketing CSS only includes classes from marketing templates" do
      css = File.read!(@compiled_path)

      # These classes belong to the React SPA, not marketing pages.
      # If they appear, Tailwind auto-detection is scanning frontend/.
      react_only_classes = [
        "focus:border-blue-500",
        "focus:ring-1",
        "disabled:opacity-50",
        "shadow-lg",
        "max-w-sm",
        "border-gray-300"
      ]

      for class <- react_only_classes do
        escaped = String.replace(class, ":", "\\:")

        refute css =~ escaped,
               "marketing.css contains '#{class}' which is a React SPA class. " <>
                 "Check that assets/css/marketing.css uses source(none) to prevent auto-detection."
      end
    end
  end
end
