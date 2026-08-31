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
| Validate against the CII XSD | `Facturx.XSD` | none (pure Elixir, OTP `:xmerl_xsd`) |
| Validate against the Schematron | `Facturx.Validate` | **optional** — `:req` + a Saxon HTTP endpoint |

### Profiles

All five Factur-X profiles are built, and `Facturx.CII.build/2` restricts what it
emits to what each one allows — a `:minimum` document is a MINIMUM document, not
an EN 16931 one wearing a MINIMUM label.

| Profile | Carries | XSD bundled | Schematron bundled |
|---|---|---|---|
| `:minimum` | header only; no VAT breakdown, no lines. Seller address only | ✅ | ✅ |
| `:basic_wl` | full header, no lines ("without lines") | ✅ | ✅ |
| `:basic` | header and lines, EN 16931-compliant subset | ✅ | ✅ |
| `:en16931` | the norm itself | ✅ | ✅ |
| `:extended` | the norm plus the French `EXT-FR-FE-*` extensions | ✅ | ✅ |

Both validators cover all five. `priv/` is 4.4 MB on disk, almost all of it
schematron, but it compresses to a 295 KB package — the five rule sets cost
78 KB of that, which is why they all ship. Each profile is checked against its
own schema *and* its own rule set in CI.

> **MINIMUM is not an invoice.** Its schema has no `ram:ApplicableTradeTax`, so
> it cannot carry the VAT breakdown (BG-23) that the French mandate requires from
> day one. It exists as an accounting aid. BASIC WL carries no lines, which the
> mandate requires on its target trajectory (BG-25). Neither is a valid French
> e-invoice; `:basic` is the leanest profile that is.

The EN 16931 Schematron ships compiled in `priv/schematron/`. `validate/2` posts
the XML + XSLT to a Saxon server and reads back the SVRL report. The XSLT resolves
a code-list DB via `document(...)`, which Saxon only permits with `--insecure`;
`docker/` provides an image that enables it and embeds the DB, so validation runs
offline. It is exercised in CI against invoices the library builds.

Deliberately **out of v1 scope** (delegate to external tools, exactly as the
Python library does):

- **Normalising an arbitrary PDF into PDF/A-3** — the caller supplies a valid
  PDF/A-3; convert upstream with Ghostscript if needed.
- **Running Schematron locally** — the EN 16931 rules are XSLT 2.0, which the
  BEAM cannot execute. `Facturx.Validate` POSTs to a Saxon server (public by
  default, self-hosted recommended in production for privacy). It is opt-in and
  disabled by default.

### Which PDFs the library accepts

`Facturx.Embed` reads and writes classic cross-reference **tables**, and works by
incremental update — the base file is preserved byte for byte and the new objects
are appended. What that rules out, each with its own error rather than a silent
wrong answer:

| Input | Result |
|---|---|
| Cross-reference **stream** (`/Type /XRef`, PDF 1.5+) | `{:error, :xref_streams_unsupported}`, and `{:error, :object_streams_unsupported}` on extraction |
| Object streams (`/ObjStm`) | same |
| PDF/A-1 | `{:error, {:unsupported_pdfa, "PDF/A-1"}}` — the standard forbids embedded files |
| Not PDF/A at all | `{:error, :not_pdfa}` |
| Already carries `/EmbeddedFiles` | `{:error, :already_has_embedded_files}` |
| Indirect `/AF` or `/Names` in the catalog | `{:error, :af_indirect_unsupported}` / `{:error, :names_indirect_unsupported}` |
| Encrypted (`/Encrypt`) | `{:error, :encrypted_pdf_unsupported}` on both paths — decrypt upstream |

Malformed input is input, not a bug: `Facturx.Embed.embed/3` and
`Facturx.Extract.extract/1` return `{:error, term()}` for any byte string
whatsoever, and never raise.

One point no error can express: **an incremental update invalidates an existing
digital signature.** That is inherent to appending to a signed file — sign after
embedding, not before.

`Facturx.Extract` is deliberately more permissive than `Facturx.Embed`: it reads
the attachment out of any PDF, PDF/A or not, because reading cannot damage the
document.

## Installation

```elixir
def deps do
  [
    {:facturx, "~> 0.7"},
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

### Notes, periods, gross prices, VAT exemption

```elixir
%Facturx.Invoice{
  # BG-1 — CII puts the content before the subject code (BT-22 then BT-21)
  notes: [%{content: "Escompte 2% sous 8 jours", subject_code: "AAB"}],
  # BG-14 — either date may stand alone
  billing_period: %{start_date: ~D[2026-07-01], end_date: ~D[2026-07-31]},
  lines: [
    %{
      net_price: Decimal.new("90.00"),
      gross_price: Decimal.new("100.00"),    # BT-148, price before discount
      price_discount: Decimal.new("10.00"),  # BT-147
      # ...
    }
  ],
  tax_breakdown: [
    %{
      category: "E",
      exemption_reason: "Exonération art. 262 ter I",  # BT-120
      exemption_reason_code: "VATEX-EU-IC",            # BT-121
      # ...
    }
  ]
}
```

### Allowances and charges

Document level (BG-20 / BG-21) and line level (BG-27 / BG-28). All four are the
same CII element told apart by `ChargeIndicator`; which list you use decides it:

```elixir
%Facturx.Invoice{
  allowances: [
    %{amount: Decimal.new("20.00"), reason: "Remise commerciale", reason_code: "95",
      basis_amount: Decimal.new("200.00"), percent: Decimal.new("10.00"),
      vat_category: "S", vat_rate: Decimal.new("20.00")}
  ],
  charges: [%{amount: Decimal.new("5.00"), reason: "Frais de port",
              vat_category: "S", vat_rate: Decimal.new("20.00")}],
  totals: %{
    line_total: Decimal.new("200.00"),
    allowance_total: Decimal.new("20.00"),   # BT-107
    charge_total: Decimal.new("5.00"),       # BT-108
    tax_basis_total: Decimal.new("185.00"),  # 200 − 20 + 5
    tax_total: Decimal.new("37.00"),
    grand_total: Decimal.new("222.00"),
    prepaid: Decimal.new("50.00"),           # BT-113 — down payments already paid
    due_payable: Decimal.new("172.00")
  }
}
```

Lines take the same `:allowances` / `:charges` keys.

> ⚠️ Two rules the XSD accepts but the platform will not:
>
> - **Every entry needs a `:reason` or `:reason_code`** (`BR-33`, `BR-38`, `BR-42`,
>   `BR-44`). An amount on its own gets the invoice rejected.
> - **Document-level entries must match their totals**, which in turn feed
>   `:tax_basis_total` (`BR-CO-11`, `BR-CO-12`, `BR-CO-13`). This library does not
>   compute that arithmetic for you.

### Payment means

How the invoice is to be paid (BG-16). Not part of the regulatory data set — the
tax administration does not need it — but an invoice without it is unusable:

```elixir
%Facturx.Invoice{
  payment_means: [
    %{
      type_code: "58",                          # BT-81, UNTDID 4461: SEPA credit transfer
      iban: "FR7630006000011234567890189",      # BT-84
      account_name: "ACME SARL",                # BT-85
      bic: "BNPAFRPPXXX"                        # BT-86
    }
  ]
}
```

`type_code` is commonly `"30"` (credit transfer), `"58"` (SEPA credit transfer),
`"59"` (SEPA direct debit), `"48"` (card), `"20"` (cheque), `"10"` (cash). The
84-value list is not validated here — the schematron already does it.

Other shapes: `:payer_iban` for a direct debit (BT-91), `:account_id` for a
non-IBAN account, `:card_id` / `:cardholder_name` for a card (BT-87 / BT-88).

> ⚠️ `:card_id` must be **at most 10 characters** — rule `BR-51` enforces the PCI
> standard of showing at most the first 6 and last 4 digits. A masked
> 16-character number like `"************1234"` is *too long* and the invoice gets
> rejected. The XSD accepts any length; only the schematron catches this.

### Down payments: referencing a preceding invoice

A final invoice nets off the down payments already invoiced, and points back at
them (BG-3). This is the counterpart of the `B4`/`S4`/`M4` invoicing frameworks:

```elixir
%Facturx.Invoice{
  business_process: "S4",   # BT-23 — final invoice after a down payment
  preceding_invoices: [
    %{number: "F-2026-042", issue_date: ~D[2026-06-15]},  # BT-25 / BT-26
    %{number: "F-2026-043"}                               # BT-26 is optional
  ],
  # ...
}
```

Rule `G1.60` forbids pairing a `B4`/`S4`/`M4` framework with `type_code` `386`,
`500` or `503`: the framework already says "final invoice after a down payment",
so the document cannot itself be one. That is enforced along with the closed list
(`validate_business_process: true`), returning
`{:error, {:final_invoice_type_conflict, %{business_process: …, type_code: …}}}`.
Being a cross-field rule, neither the XSD nor the EN 16931 schematron sees it —
the latter being French.

Two things the XSD will not catch, so worth knowing:

- `:price_discount` needs `:gross_price` — the CII price container requires an
  amount, so a lone discount is dropped.
- An exempt VAT breakdown needs a line in the matching category (`BR-E-01`), and a
  period needs its end on or after its start (`BR-29`). Both are schematron rules;
  see the Schematron section below to check them.

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

- Enabling the check also enforces **G1.60** (see the down-payment section
  above). Other French rules remain unenforced, so this is not full BT-23
  conformance.
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
case Facturx.validate(xml, endpoint: "http://localhost:5000/transform") do
  {:ok, :valid} -> :ok
  {:ok, {:valid_with_warnings, findings}} -> inspect_warnings(findings)
  {:error, {:invalid, errors}} -> reject(errors)
end
```

Findings are split by SVRL severity: only `"warning"` and `"info"` are
non-blocking. Don't read `:valid_with_warnings` as harmless — of the three
assertions the bundled schematron flags as warnings, two are business rules:
`BR-29` (BT-74 ≥ BT-73) and `BR-FX-EN-04` (a non-down-payment invoice must carry
BT-72, BG-14 or BG-26). Only `PEPPOL-EN16931-R008` (no empty elements) is
cosmetic, and it fires when neither `:ship_to` nor `:delivery_date` is set, since
CII still requires the `ram:ApplicableHeaderTradeDelivery` container.

The bundled rules load their code-list DB through `document()`, which Saxon
refuses unless started with `--insecure`. A ready-made image is provided that
enables it **and** bakes the code-list DB in, so validation needs no network:

```sh
docker compose -f docker/compose.yml up -d --build

mix test --include saxon   # with the env vars below
```

```elixir
Facturx.validate(xml,
  endpoint: "http://localhost:5000/transform",
  codedb_url: "file:///opt/facturx/FACTUR-X_EN16931_codedb.xml")
```

Without `:codedb_url`, the XSLT fetches the code-list DB over the network on every
call — slower, and it tells a third party that you are validating. See
`docker/Dockerfile` for the details, including why the upstream image's `CMD` has
to be rebuilt rather than appended to.

## License

MIT — see [`LICENSE`](LICENSE).

The XSD and Schematron artefacts bundled under `priv/` are third-party standard
schemas, not part of this library's code: Factur-X / EN 16931 (UN/CEFACT CII),
as packaged by [`akretion/factur-x`](https://github.com/akretion/factur-x)
(BSD-3-Clause). Their notices and licence texts are reproduced in
[`priv/NOTICE.md`](priv/NOTICE.md).
