defmodule Engram.MixProject do
  use Mix.Project

  def project do
    [
      app: :engram,
      version: "0.5.197",
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
      {:postgrex, ">= 0.0.0"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.2.0"},

      # Auth
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:bcrypt_elixir, "~> 3.0"},

      # Job queue
      {:oban, "~> 2.18"},

      # Markdown parsing
      {:earmark, "~> 1.4"},

      # HTTP client (Qdrant, Voyage AI)
      {:req, "~> 0.5"},

      # HTTP transport for ex_aws (S3 + KMS). ex_aws's default adapter is
      # hackney; it was previously a transitive dep of stripity_stripe.
      {:hackney, "~> 1.20"},

      # Rate limiting
      {:hammer, "~> 6.2"},

      # Telemetry & logging
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},

      # S3 storage (MinIO local, Tigris prod)
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:ex_aws_kms, "~> 2.4"},
      {:sweet_xml, "~> 0.7"},

      # Test
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},

      # Quality tooling (dev/test only — never loaded in prod release)
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
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
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "assets.deploy": ["phx.digest"]
    ]
  end
end
