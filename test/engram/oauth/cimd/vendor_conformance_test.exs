defmodule Engram.OAuth.Cimd.VendorConformanceTest do
  @moduledoc """
  Fetches the CIMD documents real vendors publish and asserts we would accept
  them.

  ## Why this exists separately from the MCPJam suite

  `scripts/mcp-conformance.sh` runs `--registration cimd`, which takes no
  client-id argument: MCPJam's CLI supplies its OWN published document. So the
  entire nightly CIMD matrix proves one thing — MCPJam can register with us —
  and it is the one vendor whose document we already accept.

  A suite that only exercises clients that already work cannot report a client
  that does not. ChatGPT was refused on every attempt for weeks while that suite
  ran green (#1633, #1635). This is the check that would have gone red.

  ## Why it is opt-in

  It makes real outbound HTTPS requests to third parties, so it is excluded by
  default and run on a schedule rather than per-PR — a vendor's brief outage must
  never be able to block a merge. Enable with `VENDOR_CONFORMANCE=1`.

  A failure here is NOT necessarily our bug. Read it as "a vendor changed
  something and one of us has to move"; the assertion message names the field.
  """
  use ExUnit.Case, async: false

  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Cimd.HttpFetcher

  @moduletag :vendor_conformance

  # Only documents whose URL has actually been observed. A guessed URL bakes in a
  # nightly failure that says nothing about the vendor, which is worse than not
  # checking it — so Claude, Grok and Mistral are absent until someone records a
  # real client_id from a live grant (`oauth_clients.cimd_url` in prod is ground
  # truth). Add the pair here; nothing else needs changing.
  @vendors [
    {"ChatGPT (connector)", "https://chatgpt.com/oauth/client.json"},
    {"ChatGPT (Codex)", "https://chatgpt.com/oauth/codex/client.json"}
  ]

  for {name, url} <- @vendors do
    test "#{name} publishes a document we accept" do
      url = unquote(url)
      name = unquote(name)

      document =
        case HttpFetcher.fetch(url) do
          {:ok, document} ->
            document

          {:error, reason} ->
            flunk("""
            #{name}: could not fetch its CIMD document.

              url:    #{url}
              reason: #{inspect(reason)}

            Either the vendor moved the document (update @vendors) or the
            endpoint is down. This is not by itself an Engram defect.
            """)
        end

      assert Cimd.validate_document(document, url) == :ok, """
      #{name}: we would REFUSE this vendor's published document.

        url:         #{url}
        refusal:     #{inspect(Cimd.validate_document(document, url))}
        auth method: #{inspect(document["token_endpoint_auth_method"])}
        jwks_uri:    #{inspect(document["jwks_uri"])}

      Every connect attempt from this vendor is currently failing with a 400 at
      OAuthAuthorizeController#show. Check `mcp_cimd_rejected` in Loki for the
      live count before deciding how urgent this is.
      """
    end
  end
end
