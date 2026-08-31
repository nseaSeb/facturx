# Tests tagged :local depend on private fixtures under test/fixtures/local/
# (real invoices, never committed). Exclude them unless those fixtures exist.
local_fixtures? = File.dir?(Path.expand("fixtures/local", __DIR__))

# Tests tagged :saxon need a live Saxon server (FACTURX_SAXON_URL).
saxon? = System.get_env("FACTURX_SAXON_URL") != nil

# Tests tagged :venv_schematron additionally need the schematron XSL of the
# profiles the library does not bundle (MINIMUM, BASIC WL, BASIC). Those weigh
# ~1.4 MB together, against 80 KB for all five XSDs, so only the XSDs ship — see
# priv/NOTICE.md. The XSL live in the dev harness venv, which is not committed.
venv_schematron? =
  saxon? and
    File.dir?(
      Path.expand(
        "../.venv-dev/lib/python3.14/site-packages/facturx/xsd_and_schematron",
        __DIR__
      )
    )

exclude =
  []
  |> then(&if(local_fixtures?, do: &1, else: [:local | &1]))
  |> then(&if(saxon?, do: &1, else: [:saxon | &1]))
  |> then(&if(venv_schematron?, do: &1, else: [:venv_schematron | &1]))

ExUnit.start(exclude: exclude)
