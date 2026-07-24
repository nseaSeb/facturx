# Facturx

Pure-Elixir toolkit for **Factur-X / ZUGFeRD** hybrid electronic invoices
(the Franco-German EN 16931 standard: a PDF/A-3 file with a machine-readable
CII XML payload embedded inside it).

The goal is to remove the need to shell out to the Python
[`akretion/factur-x`](https://github.com/akretion/factur-x) library from Elixir
projects, and to fill the gap on Hex.pm.

> Status: **v1 core complete.** `generate`, `extract`, `build`/`parse` and the
> optional `validate` all work and are proven end-to-end (veraPDF-valid output,
> parity with the Python reference, XSD-valid CII, Schematron via Saxon). See the
> scope ADR in
> [`docs/adr/0001-perimetre-et-architecture.md`](docs/adr/0001-perimetre-et-architecture.md).

## Scope (v1)

| Capability | Module | External dependency |
|---|---|---|
| Build CII XML from a struct | `Facturx.CII` | none (pure Elixir) |
| Parse CII XML into a struct | `Facturx.CII` | none (pure Elixir) |
| Extract the embedded XML from a PDF | `Facturx.Extract` | none (pure Elixir) |
| Embed XML into an existing PDF/A-3 | `Facturx.Embed` | none (pure Elixir) |
| Validate against EN 16931 XSD | `Facturx.XSD` | none (pure Elixir, OTP `:xmerl_xsd`) |
| Validate against EN 16931 Schematron | `Facturx.Validate` | **optional** — `:req` + a Saxon HTTP endpoint |

The EN 16931 Schematron ships compiled in `priv/schematron/`. `validate/2` posts
the XML + XSLT to a Saxon server (e.g. `ghcr.io/willemvlh/saxon-server`) and
reads back the SVRL report. The XSLT resolves a code-list DB via `document(...)`,
so the Saxon server must be allowed to fetch it (`:codedb_url` overrides where).

Deliberately **out of v1 scope** (delegate to external tools, exactly as the
Python library does):

- **Normalising an arbitrary PDF into PDF/A-3** — the caller supplies a valid
  PDF/A-3; convert upstream with Ghostscript if needed.
- **Running Schematron locally** — the EN 16931 rules are XSLT 2.0, which the
  BEAM cannot execute. `Facturx.Validate` POSTs to a Saxon server (public by
  default, self-hosted recommended in production for privacy). It is opt-in and
  disabled by default.

## Installation

Not published to Hex yet — use the Git dependency:

```elixir
def deps do
  [
    {:facturx, github: "nseaSeb/facturx", tag: "v0.1.0"},
    # only if you use Facturx.validate/2:
    {:req, "~> 0.5"}
  ]
end
```

## Usage

### Generate a Factur-X PDF from invoice data

The caller supplies the **visual PDF as a valid PDF/A-2 or PDF/A-3** (e.g. Typst
compiled with `--pdf-standard a-2b`). `generate/3` builds the CII XML, embeds it,
and promotes the container to PDF/A-3.

```elixir
invoice = %Facturx.Invoice{
  number: "INV-2026-001",
  issue_date: ~D[2026-07-24],
  currency: "EUR",
  seller: %{name: "ACME SARL", vat: "FR12345678900",
            address: %{line_one: "1 rue de Rivoli", postcode: "75001", city: "Paris", country: "FR"}},
  buyer: %{name: "Client SAS", vat: "FR98765432100",
           address: %{line_one: "2 place Bellecour", postcode: "69001", city: "Lyon", country: "FR"}},
  lines: [%{id: "1", name: "Service", net_price: Decimal.new("100.00"),
            quantity: Decimal.new("2"), unit: "C62",
            vat_category: "S", vat_rate: Decimal.new("20.00"), line_total: Decimal.new("200.00")}],
  tax_breakdown: [%{type: "VAT", category: "S", rate: Decimal.new("20.00"),
                    basis: Decimal.new("200.00"), calculated: Decimal.new("40.00")}],
  totals: %{line_total: Decimal.new("200.00"), tax_basis_total: Decimal.new("200.00"),
            tax_total: Decimal.new("40.00"), grand_total: Decimal.new("240.00"),
            due_payable: Decimal.new("240.00")}
}

{:ok, facturx_pdf} = Facturx.generate(pdf_a2b_binary, invoice, profile: :en16931)
# You can also pass ready-made CII XML instead of a struct:
# {:ok, facturx_pdf} = Facturx.generate(pdf_a2b_binary, cii_xml)
```

### Extract and parse a received invoice

```elixir
{:ok, %{xml: xml, profile: :en16931, filename: "factur-x.xml"}} = Facturx.extract(pdf_binary)
{:ok, %Facturx.Invoice{} = invoice} = Facturx.parse(xml)
```

### Build / parse CII XML directly

```elixir
{:ok, xml} = Facturx.build(invoice, profile: :en16931)
{:ok, invoice} = Facturx.parse(xml)
```

### Validate

XSD (structure/types) — **pure Elixir, in-process**, no external tool:

```elixir
{:ok, :valid} = Facturx.validate_xsd(xml)
# {:error, {:invalid, ["...invalid_decimal...", ...]}} on a bad document
```

Schematron (EN 16931 business rules) — needs a reachable Saxon server
(see `Facturx.Validate`):

```elixir
{:ok, :valid} = Facturx.validate(xml, endpoint: "http://localhost:5000/transform")
```

## License

MIT.
