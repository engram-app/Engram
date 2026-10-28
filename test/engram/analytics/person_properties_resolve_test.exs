defmodule Engram.Analytics.PersonPropertiesResolveTest do
  use ExUnit.Case, async: true

  alias Engram.Analytics.PersonProperties

  test "takes the highest-priority source that has a value and records it" do
    traits =
      PersonProperties.resolve(%{
        country: %{clerk: "BR"},
        language: %{app_locale: "pt-BR", browser_language: "en-US"},
        device_type: %{clerk: "mobile", posthog_initial: "desktop"}
      })

    assert traits == %{
             country: "BR",
             country_source: "clerk",
             language: "pt-BR",
             language_source: "app_locale",
             device_type: "mobile",
             device_type_source: "clerk"
           }
  end

  test "falls through to the next source when the first is missing" do
    traits =
      PersonProperties.resolve(%{
        language: %{app_locale: nil, browser_language: "ru"},
        device_type: %{clerk: "", posthog_initial: "tablet"}
      })

    assert traits.language == "ru"
    assert traits.language_source == "browser_language"
    assert traits.device_type == "tablet"
    assert traits.device_type_source == "posthog_initial"
  end

  test "a field with no source at all is left out, never set to nil" do
    assert PersonProperties.resolve(%{country: %{clerk: nil}}) == %{}
  end

  test "never overwrites a higher-priority stored value with a lower one" do
    existing = %{"language_source" => "app_locale", "device_type_source" => "clerk"}

    traits =
      PersonProperties.resolve(
        %{language: %{browser_language: "en-US"}, device_type: %{posthog_initial: "desktop"}},
        existing
      )

    assert traits == %{}
  end

  test "overwrites a lower-priority stored value with a higher one" do
    traits =
      PersonProperties.resolve(
        %{device_type: %{clerk: "mobile"}},
        %{"device_type_source" => "posthog_initial"}
      )

    assert traits.device_type == "mobile"
  end

  test "ignores PostHog geoip: country has no PostHog source" do
    assert PersonProperties.resolve(%{country: %{posthog_geoip: "US"}}) == %{}
  end
end
