defmodule Facturx.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/nseaSeb/facturx"

  def project do
    [
      app: :facturx,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      name: "Facturx",
      source_url: @source_url
    ]
  end

  # test/support holds Facturx.TestPDF, which builds synthetic PDF/A bases so the
  # Embed / Extract paths run in CI without the private fixtures. package/0 does
  # not ship test/, so nothing of it reaches Hex.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      # :xmerl (OTP) powers Facturx.XSD — pure-BEAM XSD validation, no external tool.
      extra_applications: [:logger, :xmerl],
      # Facturx.XSD.Cache compiles bundled schemas once and shares them.
      mod: {Facturx.Application, []}
    ]
  end

  # The coveralls tasks only exist in :test, so they have to select it themselves.
  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp deps do
    [
      # Pure-Elixir XML parsing/building for the CII core.
      {:saxy, "~> 1.6"},

      # Exact decimal arithmetic for monetary amounts (prices, VAT, totals).
      {:decimal, "~> 2.0"},

      # Optional: only needed by Facturx.Validate (Schematron over HTTP).
      # Callers that don't validate don't pull an HTTP client.
      {:req, "~> 0.5", optional: true},

      # Dev / docs only.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Quality gates. The public API is almost fully @spec'd; until dialyxir
      # arrived nothing checked those specs against the code.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp dialyzer do
    [
      # Facturx.XSD calls :xmerl_xsd and :xmerl_xpath directly, and OTP apps are
      # not in the PLT unless named here.
      plt_add_apps: [:xmerl],
      # Never priv/: package/0 ships priv/ to Hex, and a PLT is machine-local.
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      # No :underspecs. The public specs are deliberately wider than the success
      # typing — `{:error, term()}` is what lets a new error atom ship without
      # breaking the contract — so every one of them would be reported.
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  defp description do
    "Pure-Elixir Factur-X / ZUGFeRD e-invoicing: generate and extract hybrid " <>
      "PDF/A-3 + CII XML invoices (EN 16931), with optional Schematron validation."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv docs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      # Without this, the "source" links on hexdocs follow the default branch
      # rather than the tag the published docs were built from.
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/reference/reforme-fr.md",
        "docs/reference/mapping-cii-flux1.md",
        "docs/adr/0001-perimetre-et-architecture.md",
        "docs/adr/0002-conformite-reforme-fr.md",
        # Declared so the README's links to them resolve in the docs.
        "priv/NOTICE.md": [title: "Third-party notices"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        Référence: ~r/docs\/reference\//,
        "Décisions d'architecture": ~r/docs\/adr\//,
        Licences: ~r/(LICENSE|NOTICE)/
      ]
    ]
  end
end
