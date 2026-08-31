## What this changes

<!-- One or two sentences. If it adds a CII data item, name the BT/BG. -->

## Why

<!-- The problem, or the rule that requires it. Link the source if there is one:
     the EN 16931 rule, the French external specifications, the XSD sequence. -->

## Checks

- [ ] `mix format`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix credo --strict`
- [ ] `mix dialyzer`
- [ ] `mix test`
- [ ] For a change to the CII mapping: run against the Schematron
      (`mix test --include saxon`), fill the item in `Facturx.TestInvoice.maximal/0`,
      and tick its row in `docs/reference/mapping-cii-flux1.md`.
- [ ] `CHANGELOG.md` updated under `## Unreleased`
