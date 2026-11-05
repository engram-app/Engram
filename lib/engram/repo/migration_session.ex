defmodule Engram.Repo.MigrationSession do
  @moduledoc """
  Session settings for a non-transactional migration
  (`@disable_ddl_transaction true`): there each statement can run on a
  different pooled connection, so a bare `execute "SET ..."` can miss the
  statement it was meant for and leak into whatever runs next on its
  connection. `with_session_settings/3` pins one connection for the whole
  body, sets the settings on it and resets them in an `after`, so they
  cover exactly the body.

  Inside the body, run every statement through `repo.query!/3` (it uses the
  pinned connection); `execute/1` is buffered and runs after `up/0` returns,
  outside the checkout. Pass `timeout: :infinity` to a long statement:
  `statement_timeout` is the bound, not the client's default 15 s.

  Frozen once a merged migration calls it: a migration must not change with
  the app code, so this function's behaviour never changes. A different
  behaviour needs a new function name.
  """

  @doc "Runs `fun` on one connection of `repo` with `settings` (`[{name, value}]`) set."
  @spec with_session_settings(module(), [{String.t(), String.t()}], (-> result)) :: result
        when result: term()
  def with_session_settings(repo, settings, fun) do
    repo.checkout(fn ->
      for {name, value} <- settings,
          do: repo.query!("SELECT set_config($1, $2, false)", [name, value])

      try do
        fun.()
      after
        # RESET, parameterized: back to the session's reset value.
        for {name, _} <- settings,
            do:
              repo.query!(
                "SELECT set_config($1, (SELECT reset_val FROM pg_settings WHERE name = $1), false)",
                [name]
              )
      end
    end)
  end
end
