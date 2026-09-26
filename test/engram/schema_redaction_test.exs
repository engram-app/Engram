defmodule Engram.SchemaRedactionTest do
  @moduledoc """
  Structs holding decrypted user data must not print it. `inspect/1` is what
  crash reports, `MatchError`/`CaseClauseError` messages, Bandit's 500 log,
  Oban's `errors` column and Sentry exception values all render, and none of
  those paths run through `Engram.Logger.RedactFilter`.
  """
  use ExUnit.Case, async: true

  @canary "canary-7f3a"

  @cases [
    {Engram.Notes.Note, ~w(path folder title content type description resource)a,
     [tags: [@canary]]},
    {Engram.Attachments.Attachment, ~w(path content)a, []},
    {Engram.Links.NoteLink, ~w(target_text alias anchor)a, []},
    {Engram.Vaults.Vault, ~w(name description slug)a, []},
    {Engram.Accounts.User, ~w(email normalized_email display_name)a, []},
    {Engram.OAuth.Client, ~w(client_secret first_ip)a, []},
    {Engram.Notes.Chunk, ~w(heading_path)a, []},
    {Engram.Logs.ClientLog, ~w(message stack)a, []},
    {Engram.Auth.DeviceAuthorization, ~w(device_code user_code vault_name)a, []},
    {Engram.Email.Suppression, ~w(email)a, []},
    {Engram.Onboarding.Agreement, ~w(ip_address)a, []},
    {Engram.OAuth.RefreshToken, ~w(last_used_ip)a, []},
    {Engram.Accounts.ApiKey, ~w(name)a, []},
    {Engram.Invites.Invite, ~w(label)a, []}
  ]

  for {schema, fields, extra} <- @cases do
    test "#{inspect(schema)} never inspects its plaintext fields" do
      struct =
        struct(
          unquote(schema),
          Enum.map(unquote(fields), &{&1, "#{&1}-#{@canary}"}) ++ unquote(extra)
        )

      # The base really carries the canary, so a pass measures redaction.
      assert inspect(struct, structs: false) =~ @canary

      refute inspect(struct) =~ @canary
      refute inspect(%{wrapped: [struct]}) =~ @canary
      refute Exception.message(%MatchError{term: struct}) =~ @canary
    end
  end
end
