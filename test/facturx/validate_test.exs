defmodule Facturx.ValidateTest do
  use ExUnit.Case, async: true

  describe "interpret/1 (SVRL report parsing)" do
    test "an empty schematron-output is valid" do
      svrl = ~s(<svrl:schematron-output xmlns:svrl="http://purl.oclc.org/dsdl/svrl"/>)
      assert Facturx.Validate.interpret(svrl) == {:ok, :valid}
    end

    test "collects failed-assert and successful-report as violations" do
      svrl = """
      <svrl:schematron-output xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
        <svrl:fired-rule context="/x"/>
        <svrl:failed-assert test="exists(ram:ID)" location="/rsm:CrossIndustryInvoice">
          <svrl:text>[BR-01] An Invoice shall have a number.</svrl:text>
        </svrl:failed-assert>
        <svrl:successful-report test="warn" location="/y">
          <svrl:text>A warning fired.</svrl:text>
        </svrl:successful-report>
      </svrl:schematron-output>
      """

      assert {:error, {:invalid, violations}} = Facturx.Validate.interpret(svrl)

      assert violations == [
               %{
                 message: "[BR-01] An Invoice shall have a number.",
                 location: "/rsm:CrossIndustryInvoice",
                 test: "exists(ram:ID)"
               },
               %{message: "A warning fired.", location: "/y", test: "warn"}
             ]
    end

    test "errors on malformed SVRL" do
      assert {:error, {:invalid_svrl, _}} = Facturx.Validate.interpret("<not-closed>")
    end
  end

  describe "validate/2 without a network call" do
    test "refuses a profile whose schematron is not bundled" do
      assert Facturx.validate("<xml/>", profile: :extended) ==
               {:error, {:schematron_not_bundled, :extended}}
    end
  end

  # Live round-trip against a real Saxon server. Set FACTURX_SAXON_URL to its
  # /transform endpoint (e.g. http://localhost:5055/transform) to run it.
  describe "against a live Saxon server" do
    @describetag :saxon

    @xsl_invalid """
    <?xml version="1.0"?>
    <xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
      <xsl:template match="/">
        <svrl:schematron-output>
          <svrl:failed-assert test="t" location="/root"><svrl:text>boom</svrl:text></svrl:failed-assert>
        </svrl:schematron-output>
      </xsl:template>
    </xsl:stylesheet>
    """

    @xsl_valid """
    <?xml version="1.0"?>
    <xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
      <xsl:template match="/"><svrl:schematron-output/></xsl:template>
    </xsl:stylesheet>
    """

    setup do
      case System.get_env("FACTURX_SAXON_URL") do
        nil -> raise "set FACTURX_SAXON_URL to run :saxon tests"
        url -> {:ok, endpoint: url}
      end
    end

    test "returns :valid when the transform reports no assertions", %{endpoint: url} do
      assert Facturx.validate("<root/>", xsl: @xsl_valid, endpoint: url) == {:ok, :valid}
    end

    test "returns violations from the SVRL report", %{endpoint: url} do
      assert {:error, {:invalid, [%{message: "boom", location: "/root"}]}} =
               Facturx.validate("<root/>", xsl: @xsl_invalid, endpoint: url)
    end
  end
end
