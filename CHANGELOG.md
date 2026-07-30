# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added
- **Notes** (BG-1) — `Facturx.Invoice.notes`, a list of
  `%{content: …, subject_code: …}` (BT-22 / BT-21). CII orders the content before
  the code, the reverse of the BT numbering.
- **Invoicing period** (BG-14) — `Facturx.Invoice.billing_period`, a
  `%{start_date: …, end_date: …}` (BT-73 / BT-74). Either date may stand alone; an
  empty map emits nothing. Satisfies `BR-FX-EN-04` as an alternative to BT-72.
- **Gross price and price discount** (BT-148 / BT-147) — `:gross_price` and
  `:price_discount` on a line. `BT-148` was the **only unconditional gap** left in
  the regulatory core: mandatory inside `BG-29`, which is itself mandatory. A
  discount without a gross price is dropped, the CII price container requiring an
  amount.
- **VAT exemption reason** (BT-120 / BT-121) — `:exemption_reason` and
  `:exemption_reason_code` on a VAT breakdown entry. Note that `BR-E-01` also wants
  a line in the matching exempt category; the XSD cannot see that, the schematron
  can, and a test now pins it.

- **Preceding invoice references** (BG-3) — `Facturx.Invoice.preceding_invoices`, a
  list of `%{number: …, issue_date: …}` (BT-25 / BT-26). This is what a final
  invoice points at to net off down payments already invoiced, so it goes with the
  `B4`/`S4`/`M4` invoicing frameworks. Careful with BT-26: `FormattedIssueDateTime`
  is a `qdt:FormattedDateTimeType`, so its child is `qdt:DateTimeString` — every
  other date in the document is `udt:`. The reference block is also emitted *after*
  the monetary summation, per `HeaderTradeSettlementType`.

- **Rule G1.60 is now enforced**, alongside the G1.02 closed list and under the
  same `:validate_business_process` opt-in. A `B4`/`S4`/`M4` framework means "final
  invoice after a down payment", so it cannot be paired with a down-payment
  `:type_code` (`386`, `500`, `503`); that returns
  `{:error, {:final_invoice_type_conflict, %{business_process: …, type_code: …}}}`.
  Being a cross-field constraint, **neither the XSD nor the EN 16931 schematron
  sees it** — without the check, the first sign would be a platform refusing the
  invoice. The legitimate combinations still pass: a down-payment invoice under a
  standard framework (`S1` + `386`), and a final invoice with an ordinary type.

Coverage of the regulatory Flux 1 data set goes from 50/116 to **66/116** — see
`docs/reference/mapping-cii-flux1.md`.

### Added (tooling)
- `docker/` — a Saxon image for the bundled Schematron. It starts Saxon with
  `--insecure` (required for the `document()` call that loads the code-list DB)
  and bakes the DB in, so validation no longer fetches it over the network on
  every call. Point `:codedb_url` at `file:///opt/facturx/FACTUR-X_EN16931_codedb.xml`.
  Not shipped in the Hex package.
- **Tests against the bundled EN 16931 Schematron**, over invoices the library
  builds — until now the `:saxon` tests only exercised the HTTP transport with
  toy stylesheets, so not a single business rule was covered. Notably, one test
  pins that a BT-8 outside UNTDID 2475 is rejected *even though the XSD accepts
  it*: that is the exact defect shipped in 0.3.0, which no automated check could
  have caught.
- A `schematron` CI job running those tests. It builds the image from the commit
  under test rather than pulling a published one, so the ruleset always matches
  the code and nothing is redistributed.

## [0.4.0] - 2026-07-30

### Fixed
- **`validate/2` reported every conformant invoice as invalid.** SVRL findings
  were collected without looking at their severity, so a single `flag="warning"`
  produced `{:error, {:invalid, …}}`. The EN 16931 schematron flags
  `PEPPOL-EN16931-R008` ("no empty elements") as a warning, and CII *requires*
  `ram:ApplicableHeaderTradeDelivery` even when there is no delivery data — so any
  invoice built without `:ship_to` or `:delivery_date` tripped it and could never
  come back valid. Warnings also drowned out real errors in the same list.

### Changed (breaking)
- `Facturx.validate/2` gains a third return shape, for documents that are valid
  but carried non-blocking findings:

  ```elixir
  {:ok, :valid}
  {:ok, {:valid_with_warnings, findings}}   # new
  {:error, {:invalid, errors}}
  ```

  Callers matching on the previous two shapes must handle the new one.

  ⚠️ **Read this before upgrading.** The break has a quiet half. Code matching the
  old shapes raises a `MatchError` and fails loudly, which is fine — but code
  written as `with {:ok, _} <- Facturx.validate(xml)` or
  `match?({:ok, _}, Facturx.validate(xml))` does **not** fail. It silently starts
  accepting invoices that 0.3.0 rejected, because `{:ok, _}` can now carry failed
  assertions. Three rules are affected — every assertion the bundled schematron
  flags as `warning` — and two of them are substantive, not cosmetic:

  | Rule | What it checks | Nature |
  |---|---|---|
  | `PEPPOL-EN16931-R008` | document must not contain empty elements | cosmetic |
  | `BR-29` | if BT-73 and BT-74 are both given, BT-74 must be ≥ BT-73 | business rule |
  | `BR-FX-EN-04` | an invoice that is not a down payment (386) must carry BT-72, BG-14 or BG-26 | business rule |

  The severities are the schematron's own, not this library's choice: 0.3.0 simply
  ignored them and treated all three as blocking. If you relied on that, match on
  `{:ok, :valid}` specifically, or inspect the findings returned by
  `{:ok, {:valid_with_warnings, findings}}`.
- Findings gain a `:flag` key carrying the SVRL severity (`nil` when the rule
  declares none). Only `"warning"` and `"info"` are non-blocking; anything else,
  **including an absent flag**, counts as an error — defaulting to "invalid" is
  the safe way round. In the bundled schematron only 3 of 621 assertions are
  flagged, all as `warning`.

### Notes
- Running the bundled Schematron locally needs Saxon's `--insecure` flag, which
  permits the `document()` call that loads the code-list DB. Mind that the image's
  `CMD` must be rebuilt rather than appended to:

  ```
  docker run -d --rm -p 5000:5000 ghcr.io/willemvlh/saxon-server \
    /bin/sh -c 'java $JAVA_OPTS -jar app.jar --insecure'
  ```

## [0.3.0] - 2026-07-30

Support of the two data items the French e-invoicing mandate requires on top of
plain EN 16931. Both fields default to `nil` and emit nothing, so **generated
output is unchanged** for callers that don't set them.

### Changed
- `parse/1` now populates `business_process` (BT-23), which in 0.2.0 was always
  `nil`. Emitting is unaffected: the French closed-list check is **opt-in**, so
  `Facturx.parse(xml) |> Facturx.build()` still succeeds on a non-French document
  (a German ZUGFeRD or Peppol invoice carrying its own BT-23).

### Added
- `Facturx.Invoice.business_process` — **BT-23** "cadre de facturation"
  (`ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID`), mandatory
  `1..1` for the mandate and previously not emitted at all. This is the field
  that carries the nature of the transaction (goods / services / mixed) and
  therefore VAT chargeability.
- `Facturx.Invoice.tax_due_date_type_code` — **BT-8** VAT point date code
  (`ram:ApplicableTradeTax/ram:DueDateTypeCode`), i.e. the option to pay VAT on
  debits. Document-level and replicated onto every VAT breakdown entry, which
  satisfies rule S1.13 by construction.
- `Facturx.business_processes/0` — the closed list of 13 BT-23 codes of rule
  G1.02 (`B1`/`S1`/`M1`, `B2`/`S2`/`M2`, `B4`/`S4`/`M4`, `S5`, `S6`, `B7`/`S7`).
- `Facturx.vat_point_date_codes/0` — the BT-8 code list, `5` (invoice date, VAT on
  debits) / `29` (delivery date, goods) / `72` (payment date, VAT on collection).
  BT-8 is validated against it **by default** (`:validate_vat_point_date`, set it
  to `false` to reproduce a nonconformant third-party document), returning
  `{:error, {:invalid_vat_point_date_code, code}}`. The restriction comes from
  EN 16931 (`BR-CL-06`), not from France, and the enumeration ships in
  `priv/schematron/en16931/FACTUR-X_EN16931_codedb.xml` (code list `id=28`). Note
  that `3`/`35`/`432` are the **UBL** (UNTDID 2005) values and are invalid in CII
  — the XSD accepts them (unrestricted `xs:token`) but the Schematron does not.
- Per-entry BT-8: a `tax_breakdown` entry may carry its own `:due_date_type_code`,
  which overrides the document-level field. EN 16931 allows the code to differ
  between VAT breakdown entries even though French rule S1.13 does not, so parsing
  hoists a uniform code to the document level and keeps divergent codes per entry
  instead of collapsing them onto one value.

### Fixed
- A `:tax_due_date_type_code` with an empty `:tax_breakdown` had nowhere to be
  emitted and was dropped silently; `build/2` now returns
  `{:error, {:vat_point_date_unemittable, code}}`.
- `""` in `:business_process` or `:tax_due_date_type_code` produced an empty
  element that parsed back as `nil`, breaking the round-trip invariant. Empty
  strings are now treated as absent, like `nil`.
- `Facturx.CII.build/2` output is now covered against the bundled XSD by the test
  suite. That path had never been exercised: element order had only ever been
  checked by reading the schema.
- `:validate_business_process` option on `build/2` (and therefore `generate/3`),
  **defaulting to `false`**, also settable once via
  `config :facturx, Facturx.CII, validate_business_process: true` (the option
  overrides the config in both directions). Enabled, an unknown BT-23 code
  returns `{:error, {:invalid_business_process, code}}`. It is opt-in because
  BT-23 is an EN 16931 term whose values are *not* restricted to the French list
  — Peppol, Chorus Pro and other national specifications use their own.
- `parse/1` reads both fields back, preserving the `parse(build(inv)) == inv`
  round-trip invariant.
- Documentation, sourced against the **v3.2 (2026-04-30)** external
  specifications: `docs/reference/reforme-fr.md` (business reference, primary
  sources, and three widely repeated claims that the sources contradict),
  `docs/reference/mapping-cii-flux1.md` (all 116 regulatory Flux 1 data items
  mapped to CII, with coverage status — 50 emitted), and ADR 0002.

### Notes
- No new schema is bundled: BT-23 and BT-8 are already declared `minOccurs="0"`
  in the EN 16931 XSD shipped since 0.2.0.
- Rule **G1.60** (a `B4`/`S4`/`M4` framework forbids `type_code` `386`/`500`/`503`)
  is **not** enforced — the closed list is not full BT-23 conformance.
- There is no `:extended_ctc_fr` profile, deliberately. The PPF profile is
  declared by the transmitted file's name prefix (`Base_`/`Full_`, rule S1.06),
  which is the caller's responsibility; the URN
  `…#conformant#urn.cpro.gouv.fr:1p0:extended-ctc-fr` found in much secondary
  writing does not appear anywhere in the official specifications.

## [0.2.0] - 2026-07-24

### Added
- `Facturx.XSD.validate/2` + `Facturx.validate_xsd/2`: validate CII XML against
  the EN 16931 **XSD**, in **pure Elixir, in-process** via OTP `:xmerl_xsd` — no
  external tool, no network, no Port. Catches missing mandatory elements, wrong
  data types, unexpected elements, wrong order and cardinality. Bundled schema:
  `priv/xsd/en16931/`.
- `Facturx.XSD.Cache` (supervised): compiles each bundled schema once and shares
  it via `:persistent_term`, so validation runs in the caller process — in
  parallel, ~0.6 ms/call (vs ~5 ms recompiling per call). Falls back to per-call
  compilation in a short-lived task when no cached schema is available.

### Security
- XSD validation treats input as untrusted: a `<!DOCTYPE>` is rejected and
  external entity/DTD fetching is disabled, preventing XXE and entity-expansion
  ("billion laughs") attacks.

### Notes
- `:xmerl_xsd` is a partial XSD 1.0 implementation; it validates the CII EN 16931
  schema well but is not a guarantee of full XSD 1.0 conformance. Business-rule
  validation remains in `Facturx.Validate` (Schematron).

## [0.1.0] - 2026-07-24

First public release. Pure-Elixir generation and extraction of Factur-X /
ZUGFeRD invoices (EN 16931), with optional Schematron validation.

### Added
- Project skeleton and scope ADR.
- Public API surface: `Facturx.generate/3`, `extract/1`, `parse/1`, `build/2`, `validate/2`.
- `Facturx.Extract.extract/1`: locate and decode the embedded CII XML from a
  Factur-X PDF (classic xref), with profile detection and refc-binary-safe
  results (`:binary.copy`). Validated against a real EN 16931 fixture.
- `Facturx.Embed.embed/3` + `Facturx.generate/3`: embed CII XML into a PDF/A-2
  or PDF/A-3 base via an incremental update (embedded-file stream, `/Filespec`,
  `/AF`, `EmbeddedFiles` name tree, overridden catalog + XMP). Promotes PDF/A-2
  → PDF/A-3; refuses PDF/A-1 and non-PDF/A input. Output verified
  **PDF/A-3b-compliant by veraPDF** and semantically identical to the Python
  reference (`akretion/factur-x`).
- `Facturx.Xmp.promote/3`: bump `pdfaid:part` 2 → 3 and inject the Factur-X
  extension schema + `fx:*` properties.
- `Facturx.CII.build/2` + `parse/1`: map `Facturx.Invoice` (Decimal amounts) to
  and from EN 16931 CII XML (header, seller/buyer/ship-to, lines, VAT breakdown,
  monetary totals). Output validated against the CII XSD; `build`/`parse`
  round-trip the modelled fields (`build` fills conventional defaults — unit
  `C62`, legal scheme `0002` — which `parse` reads back).
  `Facturx.generate/3` now accepts an `Invoice` struct
  directly (struct → CII → embed → veraPDF-valid Factur-X).
- `Facturx.Validate.validate/2`: optional EN 16931 Schematron validation. Sends
  the XML + bundled compiled schematron (`priv/schematron/`) to a Saxon server
  over `multipart/form-data` (via optional `:req`) and interprets the SVRL report
  into violations. Supports a `:xsl` override for custom rule sets. Proven
  end-to-end against a live Saxon server. Note: the EN 16931 XSLT resolves a
  code-list DB via `document(...)`; the Saxon server must be configured to allow
  that URI (`:codedb_url` overrides the location).

### Known limitations
- Classic cross-reference tables only; object/xref streams (`/Type /ObjStm`,
  `/Type /XRef`) are not yet handled (`Extract` reports
  `:object_streams_unsupported`, `Embed` `:xref_streams_unsupported`).
- `Embed` uses an incremental update, so the pre-promotion (part-2) XMP remains
  earlier in the file; conformant readers resolve the latest object (veraPDF
  confirms). A full-rewrite mode may be added later.
- `Embed` merges `/AF`, `/Names` and `/PageMode` into the existing catalog
  (preserving e.g. `/Dests`). Shapes it cannot safely merge in place are
  refused, never corrupted: an indirect `/AF`/`/Names` reference, or a base that
  already carries embedded files (re-embedding into a Factur-X).
