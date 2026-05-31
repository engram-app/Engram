defmodule Engram.Sentry.ScrubberTest do
  use ExUnit.Case, async: true

  alias Engram.Sentry.Scrubber

  defp event(fields) do
    fields
    |> Map.new()
    |> Map.put_new(:event_id, "00000000000000000000000000000000")
    |> Map.put_new(:timestamp, "2026-01-01T00:00:00Z")
    |> then(&struct!(Sentry.Event, &1))
  end

  defp request(fields), do: struct!(Sentry.Interfaces.Request, fields)
  defp breadcrumb(fields), do: struct!(Sentry.Interfaces.Breadcrumb, fields)

  describe "scrub/1 — request" do
    test "drops event.request entirely (headers, cookies, query_string, data all gone)" do
      e =
        event(%{
          request:
            request(
              data: %{"customer_email" => "u@example.com"},
              headers: %{"authorization" => "Bearer secret-token"},
              cookies: "session=abc123",
              query_string: "email=u@example.com"
            )
        })

      assert %Sentry.Event{request: nil} = Scrubber.scrub(e)
    end

    test "tolerates nil request" do
      e = event(%{request: nil, extra: %{ok: "kept"}})
      assert %Sentry.Event{request: nil, extra: %{ok: "kept"}} = Scrubber.scrub(e)
    end
  end

  describe "scrub/1 — extra" do
    test "redacts email/phone/address fields in extra map" do
      e =
        event(%{
          extra: %{
            customer_email: "u@example.com",
            billing_phone: "+15551234",
            address_line1: "1 Main St",
            unrelated: "keep"
          }
        })

      scrubbed = Scrubber.scrub(e)
      assert scrubbed.extra.customer_email == "[redacted]"
      assert scrubbed.extra.billing_phone == "[redacted]"
      assert scrubbed.extra.address_line1 == "[redacted]"
      assert scrubbed.extra.unrelated == "keep"
    end

    test "redacts nested maps recursively" do
      e = event(%{extra: %{customer: %{email: "u@example.com", id: "cus_1"}}})
      scrubbed = Scrubber.scrub(e)
      assert scrubbed.extra.customer.email == "[redacted]"
      assert scrubbed.extra.customer.id == "cus_1"
    end

    test "redacts string-keyed PII fields" do
      e = event(%{extra: %{"customer" => %{"email" => "u@example.com", "id" => "cus_1"}}})
      scrubbed = Scrubber.scrub(e)
      assert scrubbed.extra["customer"]["email"] == "[redacted]"
      assert scrubbed.extra["customer"]["id"] == "cus_1"
    end

    test "recurses into lists" do
      e = event(%{extra: %{recipients: [%{email: "a@b.com"}, %{email: "c@d.com"}]}})
      scrubbed = Scrubber.scrub(e)
      assert Enum.map(scrubbed.extra.recipients, & &1.email) == ["[redacted]", "[redacted]"]
    end

    test "redacts card/iban/pan/ssn variants" do
      e =
        event(%{
          extra: %{
            card_last4: "1234",
            iban_partial: "DE00",
            pan_token: "abc",
            ssn_hint: "XXX"
          }
        })

      scrubbed = Scrubber.scrub(e)
      assert scrubbed.extra.card_last4 == "[redacted]"
      assert scrubbed.extra.iban_partial == "[redacted]"
      assert scrubbed.extra.pan_token == "[redacted]"
      assert scrubbed.extra.ssn_hint == "[redacted]"
    end
  end

  describe "scrub/1 — user/tags/contexts" do
    test "redacts PII in event.user" do
      e = event(%{user: %{email: "u@example.com", id: "user_1"}})
      scrubbed = Scrubber.scrub(e)
      assert scrubbed.user.email == "[redacted]"
      assert scrubbed.user.id == "user_1"
    end

    test "redacts PII in event.tags" do
      e = event(%{tags: %{customer_email: "u@example.com", env: "prod"}})
      scrubbed = Scrubber.scrub(e)
      assert scrubbed.tags.customer_email == "[redacted]"
      assert scrubbed.tags.env == "prod"
    end

    test "redacts PII in event.contexts (nested)" do
      e = event(%{contexts: %{runtime: %{name: "elixir"}, customer: %{email: "u@x.com"}}})
      scrubbed = Scrubber.scrub(e)
      assert scrubbed.contexts.customer.email == "[redacted]"
      assert scrubbed.contexts.runtime.name == "elixir"
    end
  end

  describe "scrub/1 — breadcrumbs" do
    test "redacts PII in breadcrumb data" do
      e =
        event(%{
          breadcrumbs: [
            breadcrumb(category: "auth", data: %{user_email: "u@x.com", id: "u_1"}),
            breadcrumb(category: "http", data: %{url: "/api/notes"})
          ]
        })

      scrubbed = Scrubber.scrub(e)
      [auth, http] = scrubbed.breadcrumbs
      assert auth.data.user_email == "[redacted]"
      assert auth.data.id == "u_1"
      assert http.data.url == "/api/notes"
    end

    test "tolerates breadcrumbs as plain maps (defensive)" do
      e = event(%{breadcrumbs: [%{category: "x", data: %{email: "u@x.com"}}]})
      scrubbed = Scrubber.scrub(e)
      [crumb] = scrubbed.breadcrumbs
      assert crumb.data.email == "[redacted]"
    end

    test "tolerates empty breadcrumbs list" do
      e = event(%{breadcrumbs: []})
      assert Scrubber.scrub(e).breadcrumbs == []
    end
  end

  test "leaves event unchanged when nothing PII-bearing is present" do
    e = event(%{extra: %{just_ids: "ok"}, user: %{id: "u_1"}, tags: %{env: "prod"}})
    scrubbed = Scrubber.scrub(e)
    assert scrubbed.extra == e.extra
    assert scrubbed.user == e.user
    assert scrubbed.tags == e.tags
  end
end
