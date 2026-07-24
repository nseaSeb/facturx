# Tests tagged :local depend on private fixtures under test/fixtures/local/
# (real invoices, never committed). Exclude them unless those fixtures exist.
local_fixtures? = File.dir?(Path.expand("fixtures/local", __DIR__))

# Tests tagged :saxon need a live Saxon server (FACTURX_SAXON_URL).
saxon? = System.get_env("FACTURX_SAXON_URL") != nil

exclude =
  []
  |> then(&if(local_fixtures?, do: &1, else: [:local | &1]))
  |> then(&if(saxon?, do: &1, else: [:saxon | &1]))

ExUnit.start(exclude: exclude)
