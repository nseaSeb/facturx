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

```elixir
def deps do
  [
    {:facturx, "~> 0.3"},
    # only if you use Facturx.validate/2:
    {:req, "~> 0.5"}
  ]
end
```

Docs: [hexdocs.pm/facturx](https://hexdocs.pm/facturx).

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

### French mandate: invoicing framework and VAT point date

Two data items are required for domestic French invoicing on top of plain
EN 16931. Both are `nil` by default, so **nothing changes if you don't need
them** — cross-border EN 16931 output is byte-for-byte unaffected.

```elixir
invoice = %Facturx.Invoice{
  business_process: "S1",        # BT-23 — cadre de facturation (closed list, see below)
  tax_due_date_type_code: "5",   # BT-8  — VAT point date code
  # ...
}
```

**BT-8** says when VAT becomes chargeable. In CII the code list is UNTDID **2475**,
restricted by EN 16931 (rule `BR-CL-06`) to three values, which
`Facturx.vat_point_date_codes/0` returns:

| Code | VAT point | Regime |
|---|---|---|
| `5` | invoice date | VAT **on debits** (chargeable on invoicing) |
| `29` | delivery date | **goods** (chargeable on delivery) |
| `72` | payment date | VAT **on collection** |

> ⚠️ `3`/`35`/`432` belong to UNTDID **2005**, the **UBL** list. In CII they pass
> the XSD (the type is an unrestricted `xs:token`) but the Schematron — and the
> platform — reject them. This library validates BT-8 against the three codes
> above **by default**, since the restriction comes from EN 16931 rather than from
> the French mandate. To reproduce a third-party document that carries a
> nonconformant code, pass `validate_vat_point_date: false`.

On the wire BT-8 sits inside each VAT breakdown entry, and EN 16931 lets the code
differ between entries (French rule S1.13 does not). The document-level field
above is the convenient case and is applied to every entry; set
`:due_date_type_code` on a `tax_breakdown` entry to override it there. Parsing
mirrors this: a uniform code is hoisted to the document level, divergent codes
stay per entry rather than being collapsed onto one value.

`business_process` (BT-23, mandatory `1..1` for the mandate) carries the nature of
the transaction, which drives VAT chargeability. Its first letter is the category
— **B**iens / **S**ervices / **M**ixte:

| | standard | already paid | final after down payment | other |
|---|---|---|---|---|
| goods | `B1` | `B2` | `B4` | `B7` e-reported |
| services | `S1` | `S2` | `S4` | `S5` subcontractor · `S6` co-contractor · `S7` e-reported |
| mixed | `M1` | `M2` | `M4` | |

The list is closed for the French mandate (rule G1.02) and
`Facturx.business_processes/0` returns it. BT-23 is an **EN 16931** term, though,
and its values are *not* restricted to those codes — Peppol uses
`urn:fdc:peppol.eu:…`, Chorus Pro used `A1`/`A2`. So the code is emitted as given
by default, and checking against the French list is **opt-in**. If you issue
French domestic invoices, enable it once in your config:

```elixir
config :facturx, Facturx.CII, validate_business_process: true
```

An unknown code then returns `{:error, {:invalid_business_process, code}}` instead
of producing an invoice a platform will reject. It can also be set per call
(`Facturx.build(invoice, validate_business_process: true)`), which overrides the
config in both directions.

Two caveats worth knowing before you rely on this:

- Rule **G1.60** (a `B4`/`S4`/`M4` framework forbids `type_code` `386`/`500`/`503`)
  is **not** enforced — the closed list is not full BT-23 conformance.
- The **Base_/Full_ file naming** that declares the PPF profile (rule S1.06) is
  the caller's or the platform's job, not this library's.

Full reference, with primary sources and the complete Flux 1 → CII mapping:
[`docs/reference/reforme-fr.md`](docs/reference/reforme-fr.md) ·
[`docs/reference/mapping-cii-flux1.md`](docs/reference/mapping-cii-flux1.md) ·
[ADR 0002](docs/adr/0002-conformite-reforme-fr.md).

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
