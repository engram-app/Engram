defmodule Engram.Analytics.DeviceTest do
  # The consent page's browser, bucketed for the redemption metrics: the
  # #2003 regression was mobile-only (Android 0/11, iOS 2/19), and nothing
  # server-side could see that.
  use ExUnit.Case, async: true

  alias Engram.Analytics.Device

  @mobile [
    ios_safari:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
    android_chrome:
      "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36",
    ios_in_app_webview:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 337.0.3.23.54",
    android_webview:
      "Mozilla/5.0 (Linux; Android 13; SM-S918B Build/TP1A.220624.014; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36",
    android_tablet_chrome:
      "Mozilla/5.0 (Linux; Android 14; SM-X910) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  ]

  @desktop [
    windows_chrome:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
    mac_safari:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
    linux_firefox: "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
  ]

  for {name, ua} <- @mobile do
    test "#{name} is mobile" do
      assert Device.from_user_agent(unquote(ua)) == "mobile"
    end
  end

  for {name, ua} <- @desktop do
    test "#{name} is desktop" do
      assert Device.from_user_agent(unquote(ua)) == "desktop"
    end
  end

  test "no user agent is unknown" do
    assert Device.from_user_agent(nil) == "unknown"
    assert Device.from_user_agent("") == "unknown"
    assert Device.from_user_agent("   ") == "unknown"
  end
end
