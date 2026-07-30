defmodule Facturx.CIIConfigTest do
  # Not async: this mutates application env, which is global. ExUnit runs sync
  # modules on their own, after the async ones, so it cannot race with them.
  use ExUnit.Case, async: false

  alias Facturx.Invoice

  @peppol "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

  setup do
    on_exit(fn -> Application.delete_env(:facturx, Facturx.CII) end)
    :ok
  end

  defp invoice(code) do
    %Invoice{
      number: "CFG-1",
      issue_date: ~D[2026-07-30],
      business_process: code,
      tax_breakdown: [%{type: "VAT", category: "S", rate: Decimal.new("20.00")}],
      totals: %{grand_total: Decimal.new("120.00")}
    }
  end

  describe "validate_business_process via application config" do
    test "off by default: a foreign BT-23 builds" do
      assert {:ok, _} = Facturx.build(invoice(@peppol))
    end

    test "config turns the French closed list on for every call" do
      Application.put_env(:facturx, Facturx.CII, validate_business_process: true)

      assert {:error, {:invalid_business_process, @peppol}} = Facturx.build(invoice(@peppol))
      assert {:ok, _} = Facturx.build(invoice("S1"))
    end

    test "an explicit option overrides the config, both ways" do
      Application.put_env(:facturx, Facturx.CII, validate_business_process: true)
      assert {:ok, _} = Facturx.build(invoice(@peppol), validate_business_process: false)

      Application.put_env(:facturx, Facturx.CII, validate_business_process: false)

      assert {:error, {:invalid_business_process, @peppol}} =
               Facturx.build(invoice(@peppol), validate_business_process: true)
    end

    test "config reaches generate/3 too" do
      Application.put_env(:facturx, Facturx.CII, validate_business_process: true)

      assert {:error, {:invalid_business_process, @peppol}} =
               Facturx.generate("%PDF-1.7 not-a-real-pdf", invoice(@peppol))
    end
  end
end
