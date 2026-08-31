# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.7.0] - 2026-08-31

### Security
- **`:decimal` moves to `~> 3.0`, a breaking dependency change.** Every 2.x is
  affected by CVE-2026-32686 (GHSA-rhv4-8758-jx7v): the exponent of a parsed
  decimal was unbounded, so `Decimal.parse("1e10000000")` succeeded and the
  first arithmetic on the result — comparing two totals, say — allocated a
  ten-million-digit coefficient and could exhaust the BEAM's memory on a single
  request. `Facturx.CII.parse/1` takes invoices from third parties and handed
  such a value straight back, so this was reachable through the public API on
  untrusted input. decimal 3 caps the exponent at 6144, the IEEE 754 decimal128
  Emax. Found by `mix hex.audit`, on its first run in CI.

  A wider requirement (`~> 2.0 or ~> 3.0`) was rejected: the resolver would keep
  picking 2.x in existing projects, which is precisely the case that needs
  fixing.

- **A non-finite amount no longer reaches an `Invoice`.** `Decimal.parse/1`
  accepts `"NaN"` and `"Infinity"`, and a hostile document could put either in a
  monetary field — where it would propagate through the caller's arithmetic and
  come back out of `build/2` as `<ram:GrandTotalAmount>NaN</ram:GrandTotalAmount>`.
  `parse/1` now reads those as absent, like any other malformed amount.

### Fixed
- **A stream is no longer cut short by its own contents.** `/Length` is now
  authoritative in both `Facturx.Embed` and `Facturx.Extract`; `endstream` and
  `endobj` are no longer located by scanning from the front of the object.
  Stream data does contain those bytes: deflate emits stored blocks that copy
  their input verbatim, and an uncompressed XMP packet can simply mention the
  word. Two failures followed, both silent until now — an embedded payload came
  back as `{:error, :inflate_failed}`, and a base whose `/Metadata` contained the
  keyword had its XMP truncated before promotion, so the output PDF lost the
  Factur-X extension schema without any error being raised. Found by the new
  property tests.

- **`Facturx.Embed.embed/3` no longer raises.** It declared
  `{:ok, binary()} | {:error, term()}` while `raise "unbalanced dictionary"` and
  a `MatchError` (no `<<` after the trailer) could both reach the caller. A
  malformed PDF is an input, not a programming error: the two sites now return
  `{:error, :malformed_dictionary}` / `{:error, :dictionary_not_found}`, and both
  `embed/3` and `Facturx.Extract.extract/1` carry a last-resort `rescue`. Pinned
  by a property over arbitrary truncations and junk suffixes.
- **Encrypted PDFs are refused instead of misread**, and only on the strength
  of a trailer dictionary. Nothing looked for
  `/Encrypt`, so an encrypted file failed to inflate or produced meaningless
  bytes. Both paths now return `{:error, :encrypted_pdf_unsupported}` — and on
  extraction that is reported in place of `:no_embedded_file`, since an
  unreadable attachment is not an absent one.

### Added
- **The MINIMUM, BASIC WL and BASIC profiles are real.** `Facturx.CII.build/2`
  used to emit the same document whatever the profile and change only the
  guideline URN, so those three produced non-conformant files carrying a
  conformant claim — and, their schemas not being bundled, nothing in the library
  could tell. `build/2` now restricts what it emits to what each profile allows,
  and all five XSDs ship (80 KB in total), along with all five schematrons. Each
  profile is checked against its own schema *and* its own rule set in CI.

  On the schematrons: `priv/` is now 4.4 MB on disk, which is what made the
  first pass bundle only two of them. That was the wrong unit — the published
  tarball goes from 217 KB to 295 KB, the five rule sets costing 78 KB between
  them. `{:error, {:schematron_not_bundled, _}}` is now reachable only for a
  profile that does not exist.

  Two findings from that work, neither visible in the XSD:

    * BT-111 (the VAT total in the accounting currency) only goes where BT-6
      goes. MINIMUM has no `TaxCurrencyCode`, so emitting it there stated an
      amount in a currency the document never declared. Every profile's schema
      allows two `TaxTotalAmount`; the build/parse fixed point is what caught it.
    * In MINIMUM the postal address and the tax registration belong to the seller
      alone — required there (BR-08, BR-09), refused on the buyer. The XSD types
      every party alike and accepts both; only the schematron says otherwise.

- `mix facturx.harness`: the PDF/A-3 conformance and Python-parity oracle, until
  now a Livebook run by hand. veraPDF over the output of all five profiles, plus
  byte parity of the payload against `akretion/factur-x`. It lives under `dev/`,
  compiled in `:dev` only, so it never reaches the published package.
- Property-based tests (`stream_data`): the build/parse fixed point over
  randomly pruned invoices, `Decimal` value *and* scale preservation, XMP
  promotion idempotence and well-formedness, and PDF payload round-trips over
  arbitrary bytes.
- Quality gates that did not exist: Dialyzer (the public API is almost entirely
  `@spec`-ed and nothing checked those specs), Credo, and coverage.
- CI now runs an OTP/Elixir matrix down to the `~> 1.15` floor declared in
  `mix.exs`, which had never been compiled.

### Changed
- The byte-level PDF rules shared by `Facturx.Embed` and `Facturx.Extract` —
  where a stream stops, where a dictionary closes, how an EOL is skipped — move
  to a single internal module, Facturx.PDF. They had been written twice and had
  to be fixed twice for the same bug.
- `README.md` documents which PDFs the library accepts and which it refuses,
  error tuple by error tuple, plus the one limit no error can express: an
  incremental update invalidates an existing digital signature.
- `Facturx.XSD.Cache` is documented rather than hidden, clearing the two
  long-standing ExDoc warnings.

## [0.6.0] - 2026-08-11

Full coverage of the French regulatory Flux 1 data set — **96/116 → 116/116** —
and the first breaking change since 0.1.0. Read the note on `:notes` below
before upgrading.

### Changed — breaking
- **A line's `:note` becomes `:notes`, a list**, taking the same
  `%{content: …, subject_code: …}` shape as the document-level field. Callers
  passing `note: "…"` must pass `notes: [%{content: "…"}]`.

  What the profile allows is no longer the caller's problem:

    * `:en16931` — one note, content only. Extra notes and any `:subject_code`
      are dropped, because emitting them gets the document rejected.
    * `:extended` — as many notes as you like, each free to carry a subject code.

  That covers **BT-127-00** (the repeated container) and **EXT-FR-FE-183** (the
  subject code), the first two of the twenty items annexe B still listed as not
  emitted.

  Note the consequence for round-tripping: an EN 16931 document cannot return
  what a caller supplied if that caller supplied more than the profile carries.

### Added
- **A line may carry its own delivery address and date** — `:ship_to` and
  `:delivery_date` on a line (`EXT-FR-FE-BG-10` and `EXT-FR-FE-BG-11` with their
  children), for the multi-delivery case where one line ships elsewhere, or on
  another date, than the document says. Same shapes as their document-level
  counterparts, both `0..1`, both `:extended` only.

  With these, **annexe B reaches 116/116** — every regulatory Flux 1 data item is
  emitted. Note the condition: 20 of them (the 19 `EXT-FR-FE-*` plus
  `BT-127-00`) exist **only in `:extended`**. `Facturx.build(inv)` still emits
  96/116 and drops the rest on purpose, rather than produce a document the schema
  and the platform would reject.

- **A line may reference a preceding invoice** — `:preceding_invoice` on a line
  (`EXT-FR-FE-BG-06` / `-136` / `-138`), what a line points at to net off a down
  payment invoiced earlier. Singular, not a list: the CII element is `0..1` at
  line level (`minOccurs="0"`, no `maxOccurs`), unlike the document-level
  `:preceding_invoices`.

  Emitted in `:extended` only, being a French extension. Two things the compiler
  will not tell you: `LineTradeSettlementType` puts it **after** the line
  monetary summation, and its date is a `qdt:DateTimeString` — the `qdt`
  namespace, not the `udt` every other date in the document uses.


- **The EXTENDED profile XSD is bundled** (`priv/xsd/extended/`), so
  `Facturx.validate_xsd/2` now accepts an EXTENDED document instead of answering
  `{:error, {:xsd_not_bundled, :extended}}`. The schema is picked from the
  document's own guideline URN, so no option is needed. This is the groundwork
  for the line-level French extensions `EXT-FR-FE-*`, which the EN 16931 schema
  rejects as out of profile.

- **The EXTENDED schematron is bundled too** (`priv/schematron/extended/`), so
  `Facturx.validate/2` checks an EXTENDED document's business rules the way it
  already did for EN 16931 — the step that catches what no XSD can see. The
  Docker image carries the matching code-list DB.

  Cost of both, measured on the published artifact rather than on disk: the Hex
  package goes from **125 KB to 209 KB**. XSLT compresses well, so the 2.2 MB
  those files occupy unpacked is not what users download.

### Fixed
- **Streams whose data ends on CR or LF were truncated by one byte.** Both
  `Facturx.Embed` and `Facturx.Extract` used to guess where a stream stopped, by
  removing the end-of-line that precedes `endstream`. When the data itself ended
  with `\r` or `\n` that guess ate a real byte. For a deflate stream the last
  byte is the low byte of the adler32, so it hit roughly **one document in
  256**: `Facturx.extract/1` returned `{:error, :inflate_failed}` on a file it
  had just produced, and a base whose `/Metadata` was deflated and ended the
  same way made `Facturx.generate/3` fail outright.

  Both now take `/Length` when it is a direct integer *and* lands on
  `endstream` with nothing but an end-of-line in between, falling back to the
  scan otherwise — producers do get `/Length` wrong, and trusting a wrong one
  would truncate where the scan worked.

### Changed
- **The PDF paths are now exercised by CI.** `Facturx.Embed` and
  `Facturx.Extract` were only ever tested against private fixtures under
  `test/fixtures/local/`, which are not committed — so every run outside the
  author's machine skipped them silently. A new test-only builder
  (`test/support/pdf_builder.ex`) assembles a minimal PDF/A base in the test
  process, and 22 tests now cover the round-trip, the XMP promotion, the catalog
  merge branches (`/Names`, `/AF`, `/PageMode`, and the shapes that are refused
  rather than corrupted), the input contract, the cross-reference offsets and
  `/Prev` chain of the incremental update, and the truncation bug above.

  The synthetic base is a structural fixture, not a PDF/A producer: real
  conformance is still proven only by the `:local` tests, which run veraPDF over
  real producer output.

- **The coverage count is now verified rather than declared.** The "Émis"
  column of annexe B (`docs/reference/mapping-cii-flux1.md`) is written by hand,
  and the count derived from it appears in the README, both ADRs and this file;
  the annexe itself records a past drift on BT-111. `Facturx.MappingAnnexeTest`
  reads the table and evaluates each of the 116 CII paths against the document
  `Facturx.CII.build/2` produces from `Facturx.TestInvoice.maximal/0`. The
  maximal invoice is also asserted XSD-valid and to round-trip exactly, which is
  what makes it a fair witness.

  What is checked is the **occurrence count**, not mere existence: nine paths are
  claimed by two rows each — BT-110 and BT-111 are both `ram:TaxTotalAmount`,
  told apart only by their `currencyID`, and the four allowance/charge families
  only by their `ChargeIndicator`. Existence alone would let one of each pair
  vanish unnoticed. A path carrying fewer nodes than it has ticked rows, or a
  path with no ticked row carrying any, fails the suite.

## [0.5.0] - 2026-07-30

The French regulatory core, complete within the EN 16931 profile: **50/116 → 96/116**
data items emitted. Additive throughout — new fields default to empty, so existing
callers see byte-identical output.

### Added
- **Notes** (BG-1) — `Facturx.Invoice.notes`, a list of
  `%{content: …, subject_code: …}` (BT-22 / BT-21). CII orders the content before
  the code, the reverse of the BT numbering.
- **Invoicing period** (BG-14) — `Facturx.Invoice.billing_period`, a
  `%{start_date: …, end_date: …}` (BT-73 / BT-74). Either date may stand alone; an
  empty map emits nothing.
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

- **Allowances and charges** (BG-20 / BG-21 at document level, BG-27 / BG-28 on a
  line) — `:allowances` and `:charges`, both on the invoice and on a line. All four
  map to one CII element told apart by `ChargeIndicator`; which list you use decides
  it, so there is no flag to get wrong. Each entry takes `:amount` (the only
  required field), `:basis_amount`, `:percent`, `:vat_category`, `:vat_rate`,
  `:reason` and `:reason_code`.
- **The remaining document totals** — `:allowance_total` (BT-107),
  `:charge_total` (BT-108), `:prepaid` (BT-113) and `:rounding` (BT-114) on
  `:totals`. `:prepaid` is what down payments already covered, so it pairs with
  `:preceding_invoices`.

  ⚠️ Two things only the schematron enforces, and which the XSD accepts happily:
  every allowance/charge needs a **`:reason` or `:reason_code`** (`BR-33`,
  `BR-38`, `BR-42`, `BR-44`) — an amount alone gets the invoice rejected; and
  document-level entries must **match their totals**, which feed
  `:tax_basis_total` in turn (`BR-CO-11`, `BR-CO-12`, `BR-CO-13`). That arithmetic
  is not computed for you.

  Note the wire order, which does not follow the numbering: CII emits
  `ChargeTotalAmount` **before** `AllowanceTotalAmount`, and
  `TradeAllowanceChargeType` puts `ReasonCode` before `Reason`.

- **Line invoicing period** (BG-26) — `:billing_period` on a line, same shape as
  the document-level one (BT-134 / BT-135). Reuses the BG-14 emitter, the CII type
  being identical; what needed care was its position, after the line's VAT and
  before its allowances.

  A note on `BR-FX-EN-04`, which lists BT-72, BG-14 and BG-26 and reads like a
  general rule: it is not one. Its template only matches invoices whose seller
  *and* buyer are in DE, so it never fires on a French invoice, and its assertion
  is a conjunction — a line period satisfies the first half only, the second still
  wanting BT-72 or a non-empty delivery container.
- **The last five core items** — `:tax_representative` (BG-11, whose BT-63 VAT id is
  the point), `:global_id` on a party (BT-29d, the SIREN of an *assujetti unique*,
  scheme `0231`), the full delivery address (`:line_two`, `:line_three`,
  `:country_subdivision` — BT-76 / BT-165 / BT-79), `:note` on a line (BT-127) and
  `:tax_currency` + `:tax_total_in_tax_currency` (BT-6 / BT-111).

  ⚠️ Two constraints the schematron caught and the XSD does not see:

  - A **line note must not carry a subject code**. That is `EXT-FR-FE-183`, a French
    extension on the target trajectory, not part of EN 16931 — emitting one gets the
    invoice rejected. Hence `:note` on a line is a plain string, with no way to ask
    for one.
  - **`:tax_currency` must differ from `:currency`.** BT-110 and BT-111 are two
    occurrences of the same element, told apart by their `currencyID`; identical
    currencies make them indistinguishable and trip `BR-53`, cascading into
    `BR-CO-15`.

  Note also that the scheme defaults (`0002`, `0231`) are written into the XML, so
  parsing a document built without them returns them anyway — the document is
  unchanged, the struct normalised.

- **Payment means** (BG-16) — `Facturx.Invoice.payment_means`, a list covering the
  credited account (`:iban` / `:account_name` / `:account_id`, BT-84 / BT-85), its
  institution (`:bic`, BT-86), a direct debit's debited account (`:payer_iban`,
  BT-91) and card details (`:card_id` / `:cardholder_name`, BT-87 / BT-88), plus
  BT-81 / BT-82. **Not** part of the regulatory Flux 1 set — the tax administration
  does not need them — so they do not enter the 96/116 count; but an invoice without
  payment details is unusable in practice.

  ⚠️ `:card_id` must be **at most 10 characters** (rule `BR-51`, the PCI standard of
  showing at most the first 6 and last 4 digits). A masked 16-character PAN like
  `"************1234"` is *too long* and gets the invoice rejected. The XSD accepts
  any length, so only the schematron catches it — pinned by a test.
- **Rule G1.60 is now enforced**, alongside the G1.02 closed list and under the
  same `:validate_business_process` opt-in. A `B4`/`S4`/`M4` framework means "final
  invoice after a down payment", so it cannot be paired with a down-payment
  `:type_code` (`386`, `500`, `503`); that returns
  `{:error, {:final_invoice_type_conflict, %{business_process: …, type_code: …}}}`.
  Being a cross-field constraint, **neither the XSD nor the EN 16931 schematron
  sees it** — without the check, the first sign would be a platform refusing the
  invoice. The legitimate combinations still pass: a down-payment invoice under a
  standard framework (`S1` + `386`), and a final invoice with an ordinary type.

Coverage of the regulatory Flux 1 data set goes from 50/116 to **96/116** — see
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
