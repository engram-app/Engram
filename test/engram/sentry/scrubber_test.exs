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

  describe "scrub/1" do
    test "drops request body" do
      e = event(%{request: request(data: %{"customer_email" => "u@example.com"})})
      assert %Sentry.Event{request: %Sentry.Interfaces.Request{data: nil}} = Scrubber.scrub(e)
    end

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

    test "leaves event unchanged when no scrubbable fields present" do
      e = event(%{extra: %{just_ids: "ok"}})
      assert Scrubber.scrub(e) == e
    end

    test "returns event when request is nil" do
      e = event(%{request: nil, extra: %{ok: "kept"}})
      assert Scrubber.scrub(e) == e
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
end
