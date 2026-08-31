# Contributing

Thanks for looking. This is a small library with a narrow, standards-driven
scope, so the most useful contributions are usually precise ones.

## Getting set up

```sh
mix deps.get
mix test
```

That runs everything CI runs, minus two suites that need more than a checkout:

- `:local` tests need real invoices under `test/fixtures/local/`, which are never
  committed. They are the conformance oracle (veraPDF, parity with the Python
  reference), and they are excluded automatically when the directory is absent.
- `:saxon` tests need a Saxon server. Bring one up with
  `docker compose -f docker/compose.yml up -d --build`, then:

  ```sh
  FACTURX_SAXON_URL=http://localhost:5000/transform \
  FACTURX_CODEDB_URL=file:///opt/facturx/FACTUR-X_EN16931_codedb.xml \
    mix test --include saxon
  ```

  On macOS, port 5000 is taken by the AirPlay receiver — it answers
  `403 AirTunes`. Map another port. Do not probe Saxon's availability with a GET:
  both its routes are POST, so a GET proves nothing. Wait for `Started @` in the
  container logs.

Note that on a development machine `mix test` does **not** reproduce the CI
condition while `test/fixtures/local/` exists. To see what the CI runner actually
does, move that directory out of the tree.

## Before opening a pull request

```sh
mix format
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
```

For a change touching `Facturx.Embed`, `Facturx.Extract` or `Facturx.PDF`, add:

```sh
mix facturx.harness
```

The suite proves structure — that what `Embed` writes, `Extract` reads back. It
cannot prove conformance: its synthetic base has no font, no OutputIntent and no
ICC profile, deliberately, so that it needs no fixtures. `mix facturx.harness`
is the oracle for the rest — veraPDF on the output of all five profiles, and
byte parity of the payload against the Python `akretion/factur-x` reference. It
needs veraPDF, the dev virtualenv and the private fixtures, and it fails rather
than reporting a success it did not establish.

## Adding a data item to the CII mapping

This sequence is not ceremony; it is what has caught the mistakes. Element order
in CII is imposed by the XSD and the compiler will not say a word about it.

1. **Read the exact XSD sequence for the type first**, before writing any code
   (`grep -A12 'complexType name="…"' priv/xsd/…`).
2. Emit **and** parse, symmetrically. `parse(build(inv))` reaching a fixed point
   is a tested invariant.
3. Test: XSD-valid, round-trip, and relative element order. Scope order
   assertions to the block concerned — names like `ram:Name` and
   `ram:ApplicableTradeTax` appear in several blocks, and lines are emitted
   before headers.
4. **Put a realistic invoice in front of the Schematron.** It is the only step
   that catches the business rules; the XSD sees neither `BR-E-01`, nor a code
   outside its list, nor any amount coherence.
5. Fill in the new item in `Facturx.TestInvoice.maximal/0` and tick its row in
   `docs/reference/mapping-cii-flux1.md`. `test/facturx/mapping_annexe_test.exs`
   evaluates that table against the built document, so an omission reads as a
   drift.
6. Document only if the public API moved.

## Scope

`docs/adr/0001-perimetre-et-architecture.md` records what this library
deliberately does not do — normalising an arbitrary PDF into PDF/A-3, and running
Schematron in-process. Please read it before proposing either.
