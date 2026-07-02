defmodule Engram.MixProject do
  use Mix.Project

  def project do
    [
      app: :engram,
      version: "0.5.595",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit],
        flags: [
          :unmatched_returns,
          :error_handling,
          :underspecs,
          :missing_return,
          :extra_return
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Engram.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "engram",
      licenses: ["PolyForm-Small-Business-1.0.0"],
      links: %{"Source" => "https://github.com/engram-app/Engram"}
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.20"},
      {:uuidv7, "~> 1.0"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.2.0"},

      # OpenAPI 3.0 spec generated from controller annotations; served at
      # GET /api/openapi and dumped to openapi.json (drift-gated in CI).
      {:open_api_spex, "~> 3.21"},

      # Auth
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:bcrypt_elixir, "~> 3.0"},

      # Job queue
      {:oban, "~> 2.18"},

      # Markdown parsing
      {:earmark, "~> 1.4"},

      # YAML parsing and generation for frontmatter codec
      {:yaml_elixir, "~> 2.11"},
      {:ymlr, "~> 5.1"},

      # Yjs CRDT engine (Rust `yrs` via Rustler NIF). Stock Hex release with
      # precompiled binaries — NO fork, NO DirtyCpu (Gate 0 spike proved
      # bounded docs stay under the 1ms NIF budget). v1 wire format only.
      {:y_ex, "~> 0.10.5"},

      # Email template rendering (MJML → responsive HTML, via mrml Rust NIF)
      {:mjml, "~> 6.0"},

      # HTTP client (Qdrant, Voyage AI)
      {:req, "~> 0.5"},

      # HTTP transport. The two real runtime consumers are ex_aws (S3 + KMS,
      # via our Engram.Storage.ExAwsHackney http_client) and Sentry (prod error
      # reporting, via its default Sentry.HackneyClient). joken_jwks lists
      # hackney as an optional dep but we drive its Tesla client with the httpc
      # adapter (config/dev.exs + config/test.exs; prod falls back to Tesla's
      # httpc default), so the JWKS path does NOT use hackney.
      #
      # 1.x (< 4.0.1) carries GHSA-gp9c-pm5m-5cxr (high — ssl:connect/2
      # post-handshake upgrade has no timeout) plus three moderate/low
      # CRLF/SSRF advisories, so we pin the 4.x line.
      #
      # `override: true` because ex_aws and joken_jwks still declare a
      # conservative `~> 1.x` requirement on hackney as an OPTIONAL dep. Both
      # ex_aws and Sentry use only the classic `:hackney.request/5` (+ body/1)
      # API, which 4.x preserves (ex_aws 2.7.0 already advertises `~> 4.0`).
      # The forced 4.x ex_aws S3/KMS path is exercised by the e2e suite.
      {:hackney, "~> 4.4", override: true},

      # Rate limiting
      {:hammer, "~> 7.3"},

      # Telemetry & logging
      {:logger_json, "~> 7.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:prom_ex, "~> 1.11"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},

      # Error reporting (no-op when SENTRY_DSN is unset, i.e. in dev/test
      # and self-host)
      {:sentry, "~> 10.0"},

      # S3 storage (MinIO local, Tigris prod)
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:ex_aws_kms, "~> 2.4"},
      {:sweet_xml, "~> 0.7"},

      # Streaming zip writer — used by Engram.Accounts.Export.Streamer to
      # build account-export archives on the fly without buffering vault
      # contents in memory.
      {:zstream, "~> 0.6"},

      # Keyword search — English (and future) stemming (pure Elixir, Snowball)
      {:text_stemmer, "~> 0.1.0"},

      # Per-chunk language detection (lingua Rust NIF — precompiled, no build-time Rust).
      # lingua pins rustler_precompiled ~> 0.8.4 conservatively; mjml pins ~> 0.9.0.
      # The override forces 0.9.x which lingua compiles and runs against fine.
      {:lingua, "~> 0.3.0"},
      {:rustler_precompiled, "~> 0.9.0", override: true},

      # Test
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},

      # Quality tooling (dev/test only — never loaded in prod release)
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Tidewave MCP — runtime introspection of the running dev app
      # (project_eval, DB queries, logs). Dev-only: it is RCE by design
      # and is mounted in the endpoint behind a code_reloading? guard.
      {:tidewave, "~> 0.5.0", only: :dev}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      # `engram.prepare_database` mirrors the prod `entrypoint.sh`:
      # cluster-level role/grant bootstrap runs BEFORE migrations so
      # the baseline dump's GRANT statements to engram_app resolve.
      "ecto.setup": [
        "ecto.create",
        "engram.prepare_database",
        "ecto.migrate",
        "run priv/repo/seeds.exs"
      ],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [
        "ecto.create --quiet",
        "engram.prepare_database",
        "ecto.migrate --quiet",
        "test"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "assets.deploy": ["phx.digest"]
    ]
  end
end
