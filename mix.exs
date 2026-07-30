defmodule Facturx.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/nseaSeb/facturx"

  def project do
    [
      app: :facturx,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Facturx",
      source_url: @source_url
    ]
  end

  def application do
    [
      # :xmerl (OTP) powers Facturx.XSD — pure-BEAM XSD validation, no external tool.
      extra_applications: [:logger, :xmerl],
      # Facturx.XSD.Cache compiles bundled schemas once and shares them.
      mod: {Facturx.Application, []}
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
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
