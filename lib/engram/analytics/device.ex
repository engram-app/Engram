defmodule Engram.Analytics.Device do
  @moduledoc """
  Buckets a browser User-Agent into `"mobile" | "desktop" | "unknown"`, a
  bounded label for the OAuth consent metrics and events. The #2003 consent
  regression was mobile-only, and nothing server-side could see that.

  Any Android, iPhone, iPod or iPad token, or a `Mobi` token, is mobile: in-app
  webviews carry those too, and an Android tablet behaves like a phone for the
  tab handoff. iPadOS Safari sends a Mac desktop UA by default, so it counts
  as desktop; nothing in the UA can tell it apart.
  """

  @mobile ~r/Android|iPhone|iPod|iPad|Mobi/

  @spec from_user_agent(String.t() | nil) :: String.t()
  def from_user_agent(ua) when is_binary(ua) do
    cond do
      String.trim(ua) == "" -> "unknown"
      Regex.match?(@mobile, ua) -> "mobile"
      true -> "desktop"
    end
  end

  def from_user_agent(_ua), do: "unknown"
end
