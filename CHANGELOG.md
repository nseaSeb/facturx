# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

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
